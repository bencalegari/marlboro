#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
TAG="marlboro-nas"
VAULT="Private"
REBOOT_NEEDED=0
COMPOSE_SERVICES=()
if [ -n "${MARLBORO_COMPOSE_SERVICES:-}" ]; then
  read -r -a COMPOSE_SERVICES <<<"$MARLBORO_COMPOSE_SERVICES"
fi


log()  { echo -e "\033[1;32m==>\033[0m $1" >&2; }
warn() { echo -e "\033[1;33mWARNING:\033[0m $1" >&2; }
err()  { echo -e "\033[1;31mERROR:\033[0m $1" >&2; exit 1; }

install_apt_packages() {
  local package missing=()
  for package in "$@"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || missing+=("$package")
  done
  [ "${#missing[@]}" -eq 0 ] && return
  log "Installing: ${missing[*]}"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

install_docker() {
  command -v docker >/dev/null && docker compose version >/dev/null 2>&1 && return
  if command -v docker >/dev/null; then
    sudo apt-get update -qq
    local compose_package
    for compose_package in docker-compose-plugin docker-compose-v2; do
      if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$compose_package" \
          && docker compose version >/dev/null 2>&1; then
        return
      fi
    done
    err "Docker is installed without Compose. Install a compatible Compose plugin and rerun setup."
  fi
  local architecture codename key_candidate source_candidate
  architecture=$(dpkg --print-architecture)
  codename=$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")
  sudo install -d -m 0755 /etc/apt/keyrings
  key_candidate=$(mktemp)
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key_candidate"
  sudo install -m 0644 "$key_candidate" /etc/apt/keyrings/docker.asc
  rm -f "$key_candidate"
  source_candidate=$(mktemp)
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$architecture" "$codename" > "$source_candidate"
  sudo install -m 0644 "$source_candidate" /etc/apt/sources.list.d/docker.list
  rm -f "$source_candidate"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_onepassword_cli() {
  command -v op >/dev/null && return
  local architecture key_candidate source_candidate
  architecture=$(dpkg --print-architecture)
  key_candidate=$(mktemp)
  curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
    | gpg --dearmor > "$key_candidate"
  sudo install -m 0644 "$key_candidate" /usr/share/keyrings/1password-archive-keyring.gpg
  rm -f "$key_candidate"
  source_candidate=$(mktemp)
  printf 'deb [arch=%s signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/%s stable main\n' \
    "$architecture" "$architecture" > "$source_candidate"
  sudo install -m 0644 "$source_candidate" /etc/apt/sources.list.d/1password.list
  rm -f "$source_candidate"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y 1password-cli
}

ensure_docker_access() {
  sudo systemctl enable docker >/dev/null
  sudo systemctl is-active --quiet docker || sudo systemctl start docker
  docker info >/dev/null 2>&1 && return
  sudo docker info >/dev/null 2>&1 || err "Docker daemon is unavailable."
  local user_name reexec_command
  user_name=$(id -un)
  sudo usermod -aG docker "$user_name"
  printf -v reexec_command '%q' "$SCRIPT_DIR/setup_script.sh"
  log "Restarting setup with Docker group access"
  exec sg docker -c "exec $reexec_command"
}

bootstrap_host_tools() {
  command -v apt-get >/dev/null || err "This setup requires an apt-based Ubuntu host."
  sudo -v
  install_apt_packages ca-certificates curl gnupg jq openssl python3 python3-yaml
  install_docker
  install_onepassword_cli
  ensure_docker_access
}

configure_docker_daemon() {
  mountpoint -q /mnt/tank || err "/mnt/tank is not mounted. Mount storage and rerun setup."
  local active_root container_count changed
  active_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
  container_count=$(docker ps -aq | wc -l | tr -d ' ')
  if [ -n "$active_root" ] && [ "$active_root" != "/mnt/tank/docker" ] && [ "$container_count" -gt 0 ]; then
    err "Docker uses $active_root with existing containers. Migrate it to /mnt/tank/docker before rerunning setup."
  fi
  sudo install -d -m 0711 /mnt/tank/docker
  changed=$(sudo python3 - <<'PY'
import json
import os

path = "/etc/docker/daemon.json"
try:
    with open(path) as handle:
        config = json.load(handle)
except FileNotFoundError:
    config = {}

desired = {"data-root": "/mnt/tank/docker", "dns": ["1.1.1.1", "8.8.8.8"]}
if all(config.get(key) == value for key, value in desired.items()):
    print("unchanged")
else:
    config.update(desired)
    temporary = path + ".tmp"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(temporary, "w") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, path)
    print("changed")
PY
)
  if [ "$changed" = "changed" ]; then
    log "Restarting Docker with managed storage and DNS"
    sudo systemctl restart docker
  fi
}

configure_kernel_tuning() {
  local destination candidate
  destination=/etc/sysctl.d/60-marlboro.conf
  candidate=$(mktemp)
  # The game server and the media stack share 8 GB. A high swappiness lets the
  # kernel page out idle Valheim heap, and faulting it back in during a tick
  # shows up to players as a stutter, so keep reclaim biased towards cache.
  printf 'vm.swappiness = 10\nvm.vfs_cache_pressure = 50\nvm.dirty_ratio = 10\nvm.dirty_background_ratio = 5\n' > "$candidate"
  if ! sudo cmp -s "$candidate" "$destination"; then
    sudo install -D -m 0644 "$candidate" "$destination"
    sudo sysctl -q --load="$destination"
  fi
  rm -f "$candidate"
}

configure_system_dns() {
  local destination candidate resolver changed=0
  destination=/etc/systemd/resolved.conf.d/adguard.conf
  candidate=$(mktemp)
  printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\nDNSStubListener=no\n' > "$candidate"
  if ! sudo cmp -s "$candidate" "$destination"; then
    sudo install -D -m 0644 "$candidate" "$destination"
    changed=1
  fi
  rm -f "$candidate"
  resolver=/run/systemd/resolve/resolv.conf
  if [ "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" != "$resolver" ]; then
    sudo ln -sfn "$resolver" /etc/resolv.conf
    changed=1
  fi
  if [ "$changed" -eq 1 ]; then
    sudo systemctl restart systemd-resolved
  fi
}

ensure_password() {
  local title="$1"
  local username="$2"

  if op item get "$title" --vault "$VAULT" &>/dev/null; then
    log "Item '$title' already exists, skipping"
  else
    log "Creating '$title' in 1Password..."
    op item create \
      --category Login \
      --title "$title" \
      --vault "$VAULT" \
      --tags "$TAG" \
      --generate-password="letters,digits,32" \
      username="$username" > /dev/null
  fi
}

ensure_secret() {
  local title="$1"
  local username="$2"
  local secret="$3"

  if op item get "$title" --vault "$VAULT" &>/dev/null; then
    log "Item '$title' already exists, skipping"
  else
    log "Creating '$title' in 1Password..."
    op item create \
      --category Login \
      --title "$title" \
      --vault "$VAULT" \
      --tags "$TAG" \
      username="$username" \
      password="$secret" > /dev/null
  fi
}

pull_field() {
  local title="$1"
  local field="$2"
  op item get "$title" --vault "$VAULT" --fields "$field" --reveal 2>/dev/null || true
}

prompt_external_item() {
  local title="$1"
  shift
  op item get "$title" --vault "$VAULT" >/dev/null 2>&1 && return
  if [ ! -t 0 ]; then
    log "WARNING: '$title' is missing; rerun interactively to configure it"
    return
  fi
  local answer field prompt value assignments=()
  read -r -p "Configure '$title' now? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { log "Skipping '$title'"; return; }
  for field in "$@"; do
    prompt=$field
    [ "$title:$field" = "Marlboro NAS - SMS Allowlist:allowlist" ] \
      && prompt="allowlist (+15551234567=seerr-display-name,...)"
    read -r -s -p "$prompt: " value
    echo ""
    [ -n "$value" ] || { log "WARNING: $field was blank; skipping '$title'"; return; }
    assignments+=("$field[text]=$value")
  done
  op item create --category "Secure Note" --title "$title" --vault "$VAULT" \
    --tags "$TAG" "${assignments[@]}" >/dev/null
  log "Created '$title'"
}

prompt_plex_claim() {
  PLEX_CLAIM_VALUE=""
  grep -qE 'PlexOnlineToken="[^"]+"' "$SCRIPT_DIR/services/plex/config/Preferences.xml" 2>/dev/null && return
  [ -t 0 ] || return 0
  read -r -s -p "Plex claim token from https://plex.tv/claim (Enter to skip): " PLEX_CLAIM_VALUE
  echo ""
}


bootstrap_host_tools
configure_docker_daemon
configure_system_dns
configure_kernel_tuning
if ! op whoami &>/dev/null; then
  log "Sign in to 1Password to continue"
  eval "$(op signin)"
fi
op whoami &>/dev/null || err "1Password sign-in failed."

log "Signed in as: $(op whoami --format=json | jq -r '.email')"
log "Ensuring credentials exist in 1Password (vault: $VAULT, tag: $TAG)..."


ensure_password "Marlboro NAS - Immich DB"            "immich"
ensure_password "Marlboro NAS - qBittorrent"          "admin"
ensure_password "Marlboro NAS - AdGuard"               "admin"
ensure_password "Marlboro NAS - Jellyfin"              "ben"
ensure_password "Marlboro NAS - Nginx Proxy Manager"  "admin@example.com"
ensure_password "Marlboro NAS - Portainer"            "admin"
ensure_password "Marlboro NAS - Sonarr"                "admin"
ensure_password "Marlboro NAS - Radarr"                "admin"
ensure_password "Marlboro NAS - Sunshine"              "admin"
ensure_password "Marlboro NAS - RomM DB"              "romm-user"
ensure_password "Marlboro NAS - RomM DB Root"         "root"
ensure_secret   "Marlboro NAS - RomM Auth Secret"     "romm" "$(openssl rand -hex 32)"

ensure_secret   "Marlboro NAS - Coolify App Key"          "coolify" "base64:$(openssl rand -base64 32)"
ensure_password "Marlboro NAS - Coolify DB"               "coolify"
ensure_secret   "Marlboro NAS - Coolify Redis"            "coolify" "$(openssl rand -hex 32)"
ensure_secret   "Marlboro NAS - Coolify Pusher App ID"    "coolify" "$(openssl rand -hex 8)"
ensure_secret   "Marlboro NAS - Coolify Pusher App Key"   "coolify" "$(openssl rand -hex 16)"
ensure_secret   "Marlboro NAS - Coolify Pusher Secret"    "coolify" "$(openssl rand -hex 32)"

ensure_secret   "Marlboro NAS - Speedtest App Key"        "speedtest" "base64:$(openssl rand -base64 32)"

ensure_password "Marlboro NAS - Forgejo"                  "ben"

ensure_password "Marlboro NAS - Samba"                    "bcalegari"

ensure_secret   "Marlboro NAS - SMS Bridge"               "sms-bridge" "$(openssl rand -hex 32)"

ensure_secret   "Marlboro NAS - Pterodactyl App Key"      "pterodactyl" "base64:$(openssl rand -base64 32)"
ensure_secret   "Marlboro NAS - Pterodactyl Hashids"      "pterodactyl" "$(openssl rand -hex 10)"
ensure_password "Marlboro NAS - Pterodactyl DB"           "pterodactyl"
ensure_password "Marlboro NAS - Pterodactyl DB Root"      "root"
ensure_password "Marlboro NAS - Pterodactyl Admin"        "ben"

prompt_external_item "Marlboro NAS - DuckDNS" token
prompt_external_item "Marlboro NAS - IGDB" client_id secret
prompt_external_item "Marlboro NAS - Screenscraper" username password
prompt_external_item "Marlboro NAS - Tailscale" api_key
prompt_external_item "Marlboro NAS - Speedtest Tracker" api_token
prompt_external_item "Marlboro NAS - Twilio" account_sid auth_token from_number
prompt_external_item "Marlboro NAS - SMS Allowlist" allowlist
prompt_external_item "github.com" token
prompt_plex_claim


write_env_file() {
  local candidate
  log "Pulling credentials from 1Password"
  candidate=$(mktemp "$SCRIPT_DIR/.env.XXXXXX")
  cat > "$candidate" <<EOF

IMMICH_DB_PASSWORD=$(pull_field "Marlboro NAS - Immich DB" password)
QBIT_PASSWORD=$(pull_field "Marlboro NAS - qBittorrent" password)
PLEX_CLAIM=
ROMM_ROOT_PASSWORD=$(pull_field "Marlboro NAS - RomM DB Root" password)
ROMM_DB_PASSWORD=$(pull_field "Marlboro NAS - RomM DB" password)
ROMM_SECRET_KEY=$(pull_field "Marlboro NAS - RomM Auth Secret" password)
DUCKDNS_TOKEN=$(pull_field "Marlboro NAS - DuckDNS" token)
IGDB_CLIENT_ID=$(pull_field "Marlboro NAS - IGDB" client_id)
IGDB_CLIENT_SECRET=$(pull_field "Marlboro NAS - IGDB" secret)
SCREENSCRAPER_USER=$(pull_field "Marlboro NAS - Screenscraper" username)
SCREENSCRAPER_PASSWORD=$(pull_field "Marlboro NAS - Screenscraper" password)
COOLIFY_APP_KEY=$(pull_field "Marlboro NAS - Coolify App Key" password)
COOLIFY_DB_PASSWORD=$(pull_field "Marlboro NAS - Coolify DB" password)
COOLIFY_REDIS_PASSWORD=$(pull_field "Marlboro NAS - Coolify Redis" password)
COOLIFY_PUSHER_APP_ID=$(pull_field "Marlboro NAS - Coolify Pusher App ID" password)
COOLIFY_PUSHER_APP_KEY=$(pull_field "Marlboro NAS - Coolify Pusher App Key" password)
COOLIFY_PUSHER_APP_SECRET=$(pull_field "Marlboro NAS - Coolify Pusher Secret" password)
SONARR_API_KEY=$(pull_field "Marlboro NAS - Sonarr" api_key)
RADARR_API_KEY=$(pull_field "Marlboro NAS - Radarr" api_key)
TAILSCALE_API_KEY=$(pull_field "Marlboro NAS - Tailscale" api_key)
TAILSCALE_HOSTNAME=$(pull_field "Marlboro NAS - Network" tailscale-hostname)
NGINX_PROXY_URL=http://nginx-proxy-manager:81
NGINX_EMAIL_ID=$(pull_field "Marlboro NAS - Nginx Proxy Manager" username)
NGINX_PASSWORD=$(pull_field "Marlboro NAS - Nginx Proxy Manager" password)
SPEEDTEST_URL=http://192.168.0.10:8765
SPEEDTEST_APP_KEY=$(pull_field "Marlboro NAS - Speedtest App Key" password)
SPEEDTEST_TRACKER_API_TOKEN=$(pull_field "Marlboro NAS - Speedtest Tracker" api_token)
GITHUB_TOKEN=$(pull_field "github.com" token)
TWILIO_ACCOUNT_SID=$(pull_field "Marlboro NAS - Twilio" account_sid)
TWILIO_AUTH_TOKEN=$(pull_field "Marlboro NAS - Twilio" auth_token)
TWILIO_FROM_NUMBER=$(pull_field "Marlboro NAS - Twilio" from_number)
SMS_ALLOWLIST=$(pull_field "Marlboro NAS - SMS Allowlist" allowlist)
SMS_BRIDGE_HOOK_SECRET=$(pull_field "Marlboro NAS - SMS Bridge" password)
SMS_BRIDGE_PUBLIC_URL=https://sms.marlboro-bc.duckdns.org/twilio/inbound
SMS_DAILY_CAP=100
PTERO_APP_KEY=$(pull_field "Marlboro NAS - Pterodactyl App Key" password)
PTERO_HASHIDS_SALT=$(pull_field "Marlboro NAS - Pterodactyl Hashids" password)
PTERO_DB_PASSWORD=$(pull_field "Marlboro NAS - Pterodactyl DB" password)
PTERO_DB_ROOT_PASSWORD=$(pull_field "Marlboro NAS - Pterodactyl DB Root" password)
PTERO_CLIENT_API_KEY=$(pull_field "Marlboro NAS - Pterodactyl Client API" api_token)
EOF

  chmod 600 "$candidate"
  if [ -f "$ENV_FILE" ] && cmp -s "$candidate" "$ENV_FILE"; then
    rm -f "$candidate"
    log ".env already matches 1Password"
  else
    mv "$candidate" "$ENV_FILE"
    log ".env updated with $(grep -c '=' "$ENV_FILE") variables"
  fi
}

write_env_file


QBIT_CONF="$SCRIPT_DIR/services/qbittorrent/config/qBittorrent/qBittorrent.conf"
QBIT_PW=$(pull_field "Marlboro NAS - qBittorrent" password)

seed_qbit_conf() {
  python3 - "$QBIT_PW" "$QBIT_CONF" "$1" <<'PY'
import sys, os, hashlib, base64, re

password, conf_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]

def make_pw_line(pw):
    salt = os.urandom(16)
    h = hashlib.pbkdf2_hmac('sha512', pw.encode(), salt, 100000, dklen=64)
    return ('WebUI\\Password_PBKDF2="@ByteArray('
            f'{base64.b64encode(salt).decode()}:{base64.b64encode(h).decode()})"')

def verify(pw, line):
    m = re.search(r'@ByteArray\(([^:]+):([^)]+)\)', line)
    if not m:
        return False
    salt = base64.b64decode(m.group(1))
    expected = base64.b64decode(m.group(2))
    return hashlib.pbkdf2_hmac('sha512', pw.encode(), salt, 100000, dklen=64) == expected

try:
    with open(conf_path) as f:
        lines = f.read().splitlines()
except FileNotFoundError:
    lines = []

pw_idx = next((i for i, l in enumerate(lines) if l.startswith('WebUI\\Password_PBKDF2=')), None)
user_idx = next((i for i, l in enumerate(lines) if l.startswith('WebUI\\Username=')), None)
hhv_idx = next((i for i, l in enumerate(lines) if l.startswith('WebUI\\HostHeaderValidation=')), None)
prefs_idx = next((i for i, l in enumerate(lines) if l.strip() == '[Preferences]'), None)

pw_ok = pw_idx is not None and verify(password, lines[pw_idx])
user_ok = user_idx is not None and lines[user_idx] == 'WebUI\\Username=admin'
hhv_ok = hhv_idx is not None and lines[hhv_idx] == 'WebUI\\HostHeaderValidation=false'

if pw_ok and user_ok and hhv_ok:
    print('unchanged')
    sys.exit(0)

if mode == 'check':
    print('needs-update')
    sys.exit(0)

if prefs_idx is None:
    lines.insert(0, '[Preferences]')
    prefs_idx = 0

if pw_idx is not None:
    lines[pw_idx] = make_pw_line(password)
else:
    lines.insert(prefs_idx + 1, make_pw_line(password))

if user_idx is not None:
    lines[user_idx] = 'WebUI\\Username=admin'
else:
    lines.insert(prefs_idx + 1, 'WebUI\\Username=admin')

if hhv_idx is not None:
    lines[hhv_idx] = 'WebUI\\HostHeaderValidation=false'
else:
    lines.insert(prefs_idx + 1, 'WebUI\\HostHeaderValidation=false')

os.makedirs(os.path.dirname(conf_path), exist_ok=True)
with open(conf_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')
print('updated')
PY
}

if [ -z "$QBIT_PW" ]; then
  log "WARNING: qBittorrent password missing in 1Password — skipping conf seed"
elif ! command -v python3 &>/dev/null; then
  log "WARNING: python3 not found — skipping qBittorrent conf seed"
else
  status=$(seed_qbit_conf check)
  if [ "$status" = "unchanged" ]; then
    log "qBittorrent WebUI credentials already match 1Password"
  else
    was_running=false
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'qbittorrent'; then
      was_running=true
      log "Stopping qbittorrent to update WebUI credentials..."
      (cd "$SCRIPT_DIR" && docker compose stop qbittorrent >/dev/null)
    fi
    seed_qbit_conf apply >/dev/null
    log "qBittorrent WebUI credentials seeded into qBittorrent.conf"
    if $was_running; then
      log "Restarting qbittorrent..."
      (cd "$SCRIPT_DIR" && docker compose up -d qbittorrent >/dev/null)
    fi
  fi
fi


SONARR_API_KEY=$(pull_field "Marlboro NAS - Sonarr" api_key)
SONARR_USER=$(pull_field "Marlboro NAS - Sonarr" username)
SONARR_PASS=$(pull_field "Marlboro NAS - Sonarr" password)
SONARR_BASE="http://localhost:8989"

reconcile_sonarr_login() {
  curl -fsS -m 5 -H "X-Api-Key: $SONARR_API_KEY" \
    "$SONARR_BASE/api/v3/system/status" >/dev/null 2>&1 || return 2

  local redirect
  redirect=$(curl -s -o /dev/null -m 5 -w '%{redirect_url}' \
    -X POST "$SONARR_BASE/login" \
    --data-urlencode "username=$SONARR_USER" \
    --data-urlencode "password=$SONARR_PASS" \
    --data-urlencode "rememberMe=off")
  if [[ "$redirect" != *loginFailed* && -n "$redirect" ]]; then
    return 0
  fi

  curl -fsS -H "X-Api-Key: $SONARR_API_KEY" "$SONARR_BASE/api/v3/config/host" \
    | jq --arg u "$SONARR_USER" --arg p "$SONARR_PASS" \
        '.username=$u | .password=$p | .passwordConfirmation=$p' \
    | curl -fsS -X PUT \
        -H "X-Api-Key: $SONARR_API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        "$SONARR_BASE/api/v3/config/host" >/dev/null
  return 1
}

if [ -z "$SONARR_API_KEY" ] || [ -z "$SONARR_USER" ] || [ -z "$SONARR_PASS" ]; then
  log "WARNING: Sonarr api_key/username/password missing in 1Password — skipping login reconcile"
elif ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'sonarr'; then
  log "Sonarr not running — skipping login reconcile (will sync on next run)"
else
  set +e; reconcile_sonarr_login; rc=$?; set -e
  case $rc in
    0) log "Sonarr WebUI credentials already match 1Password" ;;
    1) log "Sonarr WebUI credentials reconciled from 1Password (Sonarr will restart)" ;;
    2) log "WARNING: Sonarr API unreachable on :8989 — skipping login reconcile" ;;
  esac
fi


MEDIA_DIRS=(/mnt/tank/media/movies /mnt/tank/media/tv /mnt/tank/downloads/complete /mnt/tank/downloads/incomplete)

if [ -d /mnt/tank ]; then
  for dir in "${MEDIA_DIRS[@]}"; do
    [ -d "$dir" ] || sudo mkdir -p "$dir"
  done

  needs_fix=false
  for dir in "${MEDIA_DIRS[@]}"; do
    owner=$(stat -c '%u:%g' "$dir")
    if [ "$owner" != "1000:1000" ]; then
      needs_fix=true
      break
    fi
  done

  if $needs_fix; then
    log "Fixing media directory ownership (1000:1000)..."
    docker run --rm -v /mnt/tank:/mnt/tank alpine chown 1000:1000 "${MEDIA_DIRS[@]}"
  else
    log "Media directory ownership OK"
  fi
else
  log "WARNING: /mnt/tank not mounted — skipping media directory setup"
fi


PTERO_DIRS=(/mnt/tank/pterodactyl/volumes /mnt/tank/pterodactyl/archives
            /mnt/tank/pterodactyl/backups /mnt/tank/pterodactyl/logs /tmp/pterodactyl)

for dir in "${PTERO_DIRS[@]}"; do
  [ -d "$dir" ] || { sudo mkdir -p "$dir" && log "Created $dir"; }
done

for dir in db panel-var panel-logs wings-etc; do
  [ -d "$SCRIPT_DIR/services/pterodactyl/$dir" ] || mkdir -p "$SCRIPT_DIR/services/pterodactyl/$dir"
done


DOCKER_DROPIN=/etc/systemd/system/docker.service.d/wait-for-tank.conf
DOCKER_DROPIN_CONTENT='[Unit]
RequiresMountsFor=/mnt/tank
'

dropin_effective() {
  systemctl show docker -p RequiresMountsFor 2>/dev/null | grep -q '/mnt/tank'
}

if ! sudo -n true 2>/dev/null; then
  if dropin_effective; then
    log "Docker wait-for-tank drop-in active"
  else
    log "WARNING: docker is NOT waiting for /mnt/tank (guard missing or inert) — run manually:"
    echo "  sudo mkdir -p $(dirname "$DOCKER_DROPIN")"
    echo "  printf '%s' '$DOCKER_DROPIN_CONTENT' | sudo tee $DOCKER_DROPIN >/dev/null"
    echo "  sudo chmod 644 $DOCKER_DROPIN && sudo systemctl daemon-reload"
    echo "  systemctl show docker -p RequiresMountsFor   # verify: must list /mnt/tank"
  fi
else
  if [ "$(sudo cat "$DOCKER_DROPIN" 2>/dev/null)" != "$DOCKER_DROPIN_CONTENT" ]; then
    log "Installing docker.service wait-for-tank drop-in..."
    sudo mkdir -p "$(dirname "$DOCKER_DROPIN")"
    printf '%s' "$DOCKER_DROPIN_CONTENT" | sudo tee "$DOCKER_DROPIN" >/dev/null
    sudo chmod 644 "$DOCKER_DROPIN"
  fi
  if dropin_effective; then
    log "Docker wait-for-tank drop-in active"
  else
    log "Loading docker wait-for-tank drop-in (daemon-reload)..."
    sudo systemctl daemon-reload
    dropin_effective || log "WARNING: drop-in still not effective after reload — a reboot may be required"
  fi
fi


if command -v tailscale &>/dev/null; then
  if ! op item get "Marlboro NAS - Network" --vault "$VAULT" &>/dev/null; then
    log "Storing network details in 1Password..."
    op item create \
      --category "Secure Note" \
      --title "Marlboro NAS - Network" \
      --vault "$VAULT" \
      --tags "$TAG" \
      "static-ip[text]=$(ip -4 addr show enp4s0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)" \
      "tailscale-hostname[text]=$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')" \
      "tailscale-ip[text]=$(tailscale ip -4)" > /dev/null
  else
    log "Item 'Marlboro NAS - Network' already exists, skipping"
  fi
fi

configure_sunshine() {
  local USER_NAME CONF_DIR SWAY_DIR UNIT_DIR AS_FILE GDM_CONF
  local SUNSHINE_VERSION DEB DEB_URL IDLE_TIMEOUT ICON RA_SVG ORIGINS bak tmp
  local -a PKGS
  USER_NAME="$(id -un)"
  CONF_DIR="$HOME/.config/sunshine"
  SWAY_DIR="$HOME/.config/sway"
  UNIT_DIR="$HOME/.config/systemd/user"
  AS_FILE="/var/lib/AccountsService/users/$USER_NAME"
  GDM_CONF="/etc/gdm3/custom.conf"
  SUNSHINE_VERSION="v2026.516.143833"
  DEB="sunshine-ubuntu-26.04-amd64.deb"
  DEB_URL="https://github.com/LizardByte/Sunshine/releases/download/${SUNSHINE_VERSION}/${DEB}"
  IDLE_TIMEOUT=300

  log "Sunshine: provisioning stream host (sway + KMS)"
  if [ "$(id -u)" -eq 0 ]; then log "  running as root — skipping Sunshine (needs normal user for \$HOME + systemctl --user)"; return; fi
  command -v curl >/dev/null || { log "  curl not found — skipping Sunshine"; return; }
  mkdir -p "$CONF_DIR" "$SWAY_DIR" "$UNIT_DIR"

  systemctl --user disable --now weston.service 2>/dev/null || true
  if [ -f "$UNIT_DIR/sunshine.service" ] && grep -q 'sunshine.AppImage' "$UNIT_DIR/sunshine.service"; then rm -f "$UNIT_DIR/sunshine.service"; fi
  rm -f "$UNIT_DIR/weston.service"
  if flatpak list --columns=application 2>/dev/null | grep -qx dev.lizardbyte.app.Sunshine; then
    log "  removing Flatpak Sunshine (can't KMS-capture)…"; sudo flatpak uninstall -y --system dev.lizardbyte.app.Sunshine
  fi

  PKGS=()
  command -v sway         >/dev/null || PKGS+=(sway)
  command -v swayidle     >/dev/null || PKGS+=(swayidle)
  command -v retroarch    >/dev/null || PKGS+=(retroarch)
  command -v rsvg-convert >/dev/null || PKGS+=(librsvg2-bin)
  if [ "${#PKGS[@]}" -gt 0 ]; then log "  installing: ${PKGS[*]}…"; sudo apt-get update -qq; sudo apt-get install -y "${PKGS[@]}"; fi

  if ! dpkg-query -W sunshine >/dev/null 2>&1; then
    log "  installing $DEB ($SUNSHINE_VERSION)…"
    tmp="$(mktemp -d)"
    if ! curl -fL "$DEB_URL" -o "$tmp/$DEB"; then log "  ERROR: download failed: $DEB_URL — skipping Sunshine"; rm -rf "$tmp"; return; fi
    sudo apt-get install -y "$tmp/$DEB"; rm -rf "$tmp"
  else
    log "  sunshine already installed (dpkg $(dpkg-query -W -f='${Version}' sunshine))"
  fi
  getcap /usr/bin/sunshine 2>/dev/null | grep -q cap_sys_admin || log "  WARNING: /usr/bin/sunshine missing cap_sys_admin — KMS capture will fail (reinstall the .deb)"

  if ! id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx input; then log "  adding $USER_NAME to 'input' group…"; sudo usermod -aG input "$USER_NAME"; REBOOT_NEEDED=1; fi

  if [ -f "$GDM_CONF" ] && ! grep -qE '^\s*AutomaticLoginEnable\s*=\s*[Tt]rue' "$GDM_CONF"; then
    log "  enabling GDM autologin for $USER_NAME…"
    sudo sed -i -E "/^\[daemon\]/a AutomaticLoginEnable=True\nAutomaticLogin=$USER_NAME" "$GDM_CONF"; REBOOT_NEEDED=1
  fi
  if ! sudo grep -qE '^\s*Session\s*=\s*sway' "$AS_FILE" 2>/dev/null; then
    log "  setting autologin session -> sway…"
    sudo python3 - "$AS_FILE" <<'PY'
import configparser, os, sys
p = sys.argv[1]
c = configparser.ConfigParser(); c.optionxform = str
if os.path.exists(p): c.read(p)
if not c.has_section("User"): c.add_section("User")
c["User"]["Session"] = "sway"
c["User"]["XSession"] = "sway"
with open(p, "w") as f:
    for s in c.sections():
        f.write("[%s]\n" % s)
        for k, v in c[s].items(): f.write("%s=%s\n" % (k, v))
        f.write("\n")
PY
    REBOOT_NEEDED=1
  fi

  log "  writing sway config + sway-session.target…"
  cat > "$SWAY_DIR/config" <<'EOF'
include /etc/sway/config

exec systemctl --user import-environment WAYLAND_DISPLAY DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP && \
     dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP=sway && \
     systemctl --user start sway-session.target

output * power on
EOF
  cat > "$UNIT_DIR/sway-session.target" <<'EOF'
[Unit]
Description=sway compositor session
Documentation=man:systemd.special(7)
BindsTo=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target
EOF

  log "  writing display.sh + swayidle.service (idle ${IDLE_TIMEOUT}s)…"
  cat > "$CONF_DIR/display.sh" <<'EOF'
#!/bin/bash
export SWAYSOCK="${SWAYSOCK:-$(ls -t /run/user/$(id -u)/sway-ipc.*.sock 2>/dev/null | head -1)}"
case "$1" in
  wake)         swaymsg 'output * power on' ;;
  blank)        swaymsg 'output * power off' ;;
  stream-start) swaymsg 'output * power on'; systemctl --user stop swayidle.service ;;
  stream-end)   systemctl --user restart swayidle.service ;;
  *) echo "usage: display.sh {blank|wake|stream-start|stream-end}" >&2; exit 2 ;;
esac
EOF
  chmod +x "$CONF_DIR/display.sh"
  cat > "$UNIT_DIR/swayidle.service" <<EOF
[Unit]
Description=swayidle - blank the shared monitor after inactivity
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/swayidle -w timeout $IDLE_TIMEOUT '$CONF_DIR/display.sh blank' resume '$CONF_DIR/display.sh wake'
Restart=on-failure

[Install]
WantedBy=graphical-session.target
EOF

  ICON="$CONF_DIR/retroarch.png"
  RA_SVG="/usr/share/icons/hicolor/scalable/apps/com.libretro.RetroArch.svg"
  if [ ! -f "$ICON" ]; then
    if command -v rsvg-convert >/dev/null && [ -f "$RA_SVG" ]; then log "  rendering RetroArch icon…"; rsvg-convert -w 256 -h 256 "$RA_SVG" -o "$ICON"
    elif [ -f /usr/share/sunshine/box.png ]; then cp /usr/share/sunshine/box.png "$ICON"; fi
  fi

  ORIGINS="$(ip -4 -o addr show scope global 2>/dev/null \
             | awk '$2 !~ /^(docker|br-|veth|virbr|lo)/ {print $4}' | cut -d/ -f1 \
             | sed 's#^#https://#; s#$#:47990#' | paste -sd, -)"
  if [ ! -f "$CONF_DIR/sunshine.conf" ] \
     || ! grep -qE '^\s*capture\s*=\s*kms' "$CONF_DIR/sunshine.conf" \
     || ! grep -q 'global_prep_cmd' "$CONF_DIR/sunshine.conf"; then
    if [ -f "$CONF_DIR/sunshine.conf" ]; then
      bak="$CONF_DIR/sunshine.conf.bak.$(date +%Y%m%d%H%M%S)"
      log "  stale sunshine.conf — backing up -> $bak and rewriting"; cp -a "$CONF_DIR/sunshine.conf" "$bak"
    fi
    log "  writing sunshine.conf (kms + vaapi + csrf + global_prep_cmd)…"
    cat > "$CONF_DIR/sunshine.conf" <<EOF
capture = kms
encoder = vaapi
adapter_name = /dev/dri/renderD128
origin_web_ui_allowed = wan
csrf_allowed_origins = $ORIGINS
global_prep_cmd = [{"do":"$CONF_DIR/display.sh stream-start","undo":"$CONF_DIR/display.sh stream-end","elevated":"false"}]
EOF
    sed -i '/^csrf_allowed_origins = *$/d' "$CONF_DIR/sunshine.conf"
  fi

  if [ ! -f "$CONF_DIR/apps.json" ]; then
    log "  seeding apps.json (Desktop / Steam / RetroArch)…"
    cat > "$CONF_DIR/apps.json" <<'EOF'
{
  "env": { "PATH": "$(PATH):$(HOME)/.local/bin" },
  "apps": [
    { "name": "Desktop", "image-path": "desktop.png" },
    {
      "name": "Steam Big Picture",
      "detached": ["setsid steam steam://open/bigpicture"],
      "prep-cmd": [ { "do": "", "undo": "setsid steam steam://close/bigpicture" } ],
      "image-path": "steam.png"
    },
    { "name": "RetroArch", "cmd": "retroarch", "auto-detach": false, "image-path": "__ICON__" }
  ]
}
EOF
    sed -i "s#__ICON__#$ICON#" "$CONF_DIR/apps.json"
  fi

  if [ -f "$CONF_DIR/sunshine_state.json" ] && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("username") else 1)' "$CONF_DIR/sunshine_state.json" 2>/dev/null; then
    log "  web-UI credentials already set — leaving as-is (clear them to re-seed from 1Password)"
  else
    local s_user s_pass was_active
    s_user=$(pull_field "Marlboro NAS - Sunshine" username)
    s_pass=$(pull_field "Marlboro NAS - Sunshine" password)
    if [ -n "$s_user" ] && [ -n "$s_pass" ]; then
      log "  seeding web-UI credentials from 1Password (Marlboro NAS - Sunshine)…"
      was_active=0; systemctl --user is-active --quiet app-dev.lizardbyte.app.Sunshine.service && was_active=1
      [ "$was_active" -eq 1 ] && systemctl --user stop app-dev.lizardbyte.app.Sunshine.service
      if sunshine --creds "$s_user" "$s_pass" >/dev/null 2>&1; then
        log "  credentials set (Sunshine-hashed; pairings preserved)"
      else
        log "  WARNING: 'sunshine --creds' failed — set the password in the web UI"
      fi
      [ "$was_active" -eq 1 ] && systemctl --user start app-dev.lizardbyte.app.Sunshine.service
    else
      log "  'Marlboro NAS - Sunshine' username/password not in 1Password — set the web-UI login manually"
    fi
  fi

  log "  writing Sunshine ExecStartPre wake drop-in…"
  local DROPIN_DIR="$UNIT_DIR/app-dev.lizardbyte.app.Sunshine.service.d"
  mkdir -p "$DROPIN_DIR"
  cat > "$DROPIN_DIR/override.conf" <<EOF
[Service]
ExecStartPre=-$CONF_DIR/display.sh wake
ExecStartPre=-/usr/bin/systemctl --user restart swayidle.service
EOF

  systemctl --user daemon-reload
  systemctl --user enable app-dev.lizardbyte.app.Sunshine.service >/dev/null 2>&1 || true
  systemctl --user enable swayidle.service >/dev/null 2>&1 || true
  log "  Sunshine provisioned (services enabled; start on next sway session)"
}
[ "${MARLBORO_SKIP_SUNSHINE:-0}" = "1" ] || configure_sunshine

configure_samba() {
  log "Provisioning Samba (SMB share of /mnt/tank)…"
  local SMB_USER="bcalegari" WORKGROUP="WORKGROUP" LAN_IFACES="enp4s0 wlp3s0"
  local SMB_ITEM="Marlboro NAS - Samba"

  [ -d /mnt/tank ] || { log "  WARNING: /mnt/tank not mounted — skipping Samba"; return; }

  local need_pkgs=()
  dpkg -s samba &>/dev/null || need_pkgs+=(samba)
  dpkg -s wsdd  &>/dev/null || need_pkgs+=(wsdd)
  if [ ${#need_pkgs[@]} -gt 0 ]; then
    log "  installing: ${need_pkgs[*]}"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${need_pkgs[@]}"
  else
    log "  samba + wsdd already installed"
  fi

  local SMB_PASS; SMB_PASS=$(pull_field "$SMB_ITEM" password)
  [ -n "$SMB_PASS" ] || { log "  WARNING: '$SMB_ITEM' password blank in 1Password — skipping Samba"; return; }
  id "$SMB_USER" &>/dev/null || { log "  WARNING: unix user '$SMB_USER' missing — skipping Samba"; return; }
  if sudo pdbedit -L 2>/dev/null | grep -q "^${SMB_USER}:"; then
    log "  syncing SMB password for '$SMB_USER'"
    printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | sudo smbpasswd -s "$SMB_USER"
  else
    log "  adding SMB user '$SMB_USER'"
    printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | sudo smbpasswd -s -a "$SMB_USER"
  fi
  sudo smbpasswd -e "$SMB_USER" >/dev/null

  local d
  for d in /mnt/tank/media /mnt/tank/downloads; do
    [ -d "$d" ] || { log "  WARNING: missing share path $d — skipping Samba"; return; }
  done

  local samba_changed=0 avahi_changed=0 wsdd_changed=0
  local samba_candidate avahi_candidate wsdd_candidate
  samba_candidate=$(mktemp)
  cat > "$samba_candidate" <<EOF
[global]
   workgroup = ${WORKGROUP}
   server string = Marlboro NAS
   server role = standalone server
   security = user
   map to guest = never
   passdb backend = tdbsam

   hosts allow = 127.0.0.0/8 192.168.0.0/24 100.64.0.0/10 fc00::/7 ::1
   hosts deny = 0.0.0.0/0 ::/0

   server min protocol = SMB3_00
   client min protocol = SMB3_00
   smb encrypt = desired

   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:nfs_aces = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

   socket options = TCP_NODELAY IPTOS_LOWDELAY
   use sendfile = yes
   aio read size = 1
   aio write size = 1

[media]
   comment = Movies, TV, ROMs
   path = /mnt/tank/media
   browseable = yes
   read only = no
   valid users = ${SMB_USER}
   force user = ${SMB_USER}
   force group = ${SMB_USER}
   create mask = 0664
   directory mask = 0775

[downloads]
   comment = Torrent downloads
   path = /mnt/tank/downloads
   browseable = yes
   read only = no
   valid users = ${SMB_USER}
   force user = ${SMB_USER}
   force group = ${SMB_USER}
   create mask = 0664
   directory mask = 0775
EOF
  if ! testparm -s "$samba_candidate" >/dev/null 2>&1; then
    rm -f "$samba_candidate"
    log "  WARNING: testparm rejected smb.conf — skipping Samba restart"
    return
  fi
  if ! sudo cmp -s "$samba_candidate" /etc/samba/smb.conf; then
    sudo install -D -m 0644 "$samba_candidate" /etc/samba/smb.conf
    samba_changed=1
    log "  updated /etc/samba/smb.conf"
  fi
  rm -f "$samba_candidate"

  avahi_candidate=$(mktemp)
  cat > "$avahi_candidate" <<'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h</name>
  <service>
    <type>_smb._tcp</type>
    <port>445</port>
  </service>
  <service>
    <type>_device-info._tcp</type>
    <port>0</port>
    <txt-record>model=RackMac</txt-record>
  </service>
</service-group>
EOF
  if ! sudo cmp -s "$avahi_candidate" /etc/avahi/services/samba.service; then
    sudo install -D -m 0644 "$avahi_candidate" /etc/avahi/services/samba.service
    avahi_changed=1
    log "  updated /etc/avahi/services/samba.service"
  fi
  rm -f "$avahi_candidate"

  local WSDD_IFACE_ARGS="" i
  for i in ${LAN_IFACES}; do WSDD_IFACE_ARGS+=" --interface ${i}"; done
  if command -v wsdd &>/dev/null; then
    wsdd_candidate=$(mktemp)
    cat > "$wsdd_candidate" <<EOF
[Unit]
Description=Web Services Dynamic Discovery host daemon (Windows network browsing)
Documentation=man:wsdd(8)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/wsdd --workgroup ${WORKGROUP}${WSDD_IFACE_ARGS}
User=nobody
Group=nogroup
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    if ! sudo cmp -s "$wsdd_candidate" /etc/systemd/system/wsdd.service; then
      sudo install -D -m 0644 "$wsdd_candidate" /etc/systemd/system/wsdd.service
      sudo systemctl daemon-reload
      wsdd_changed=1
      log "  updated /etc/systemd/system/wsdd.service"
    fi
    rm -f "$wsdd_candidate"
  fi

  sudo systemctl enable smbd >/dev/null 2>&1 || true
  if [ "$samba_changed" -eq 1 ] || ! sudo systemctl is-active --quiet smbd; then
    sudo systemctl restart smbd \
      || { log "  WARNING: smbd failed to start — check: sudo systemctl status smbd"; return; }
  fi
  sudo systemctl enable nmbd >/dev/null 2>&1 || true
  if [ "$samba_changed" -eq 1 ] || ! sudo systemctl is-active --quiet nmbd; then
    sudo systemctl restart nmbd || log "  WARNING: nmbd failed to start — SMB discovery degraded"
  fi
  sudo systemctl enable avahi-daemon >/dev/null 2>&1 || true
  if [ "$avahi_changed" -eq 1 ] || ! sudo systemctl is-active --quiet avahi-daemon; then
    sudo systemctl restart avahi-daemon || log "  WARNING: avahi-daemon failed to start — SMB discovery degraded"
  fi
  if command -v wsdd &>/dev/null; then
    sudo systemctl enable wsdd >/dev/null 2>&1 || true
    if [ "$wsdd_changed" -eq 1 ] || ! sudo systemctl is-active --quiet wsdd; then
      sudo systemctl restart wsdd || log "  WARNING: wsdd failed to start — SMB discovery degraded"
    fi
  fi
  log "  Samba live — shares: media (rw), downloads (rw); user $SMB_USER"
}

sync_arr_api_keys() {
  local spec service title config key current attempt
  for spec in \
    "sonarr|Marlboro NAS - Sonarr|$SCRIPT_DIR/services/sonarr/config/config.xml" \
    "radarr|Marlboro NAS - Radarr|$SCRIPT_DIR/services/radarr/config/config.xml"; do
    IFS='|' read -r service title config <<<"$spec"
    docker inspect "$service" >/dev/null 2>&1 || continue
    key=""
    for attempt in {1..60}; do
      key=$(grep -oE '<ApiKey>[^<]+' "$config" 2>/dev/null | sed 's/<ApiKey>//' || true)
      [ -n "$key" ] && break
      sleep 2
    done
    [ -n "$key" ] || { log "WARNING: $title API key is not available yet"; continue; }
    current=$(pull_field "$title" api_key)
    if [ "$current" = "$key" ]; then
      log "$title API key already matches 1Password"
    else
      op item edit "$title" --vault "$VAULT" "api_key[text]=$key" >/dev/null
      log "$title API key stored in 1Password"
    fi
  done
}

wait_for_service_initialization() {
  local attempt prowlarr_ready npm_ready panel_ready jellyfin_ready portainer_ready forgejo_ready scrutiny_ready
  for attempt in {1..100}; do
    prowlarr_ready=1 npm_ready=1 panel_ready=1 jellyfin_ready=1
    portainer_ready=1 forgejo_ready=1 scrutiny_ready=1
    if docker inspect prowlarr >/dev/null 2>&1; then
      grep -q '<ApiKey>[^<]' "$SCRIPT_DIR/services/prowlarr/config/config.xml" 2>/dev/null || prowlarr_ready=0
    fi
    if docker inspect nginx-proxy-manager >/dev/null 2>&1; then
      curl -fsS -m2 http://localhost:81/api/ >/dev/null 2>&1 || npm_ready=0
    fi
    if docker inspect pterodactyl-panel >/dev/null 2>&1; then
      [ "$(docker inspect --format '{{.State.Health.Status}}' pterodactyl-panel 2>/dev/null || true)" = "healthy" ] || panel_ready=0
    fi
    if docker inspect jellyfin >/dev/null 2>&1; then
      curl -fsS -m2 http://localhost:8096/System/Info/Public >/dev/null 2>&1 || jellyfin_ready=0
    fi
    if docker inspect portainer >/dev/null 2>&1; then
      curl -sS -m2 -o /dev/null http://localhost:9000/api/users/admin/check || portainer_ready=0
    fi
    if docker inspect forgejo >/dev/null 2>&1; then
      curl -fsS -m2 http://localhost:3003/api/healthz >/dev/null 2>&1 || forgejo_ready=0
    fi
    if docker inspect scrutiny >/dev/null 2>&1; then
      curl -fsS -m2 http://localhost:8085/api/settings >/dev/null 2>&1 || scrutiny_ready=0
    fi
    if [ "$prowlarr_ready$npm_ready$panel_ready$jellyfin_ready$portainer_ready$forgejo_ready$scrutiny_ready" = "1111111" ]; then
      return
    fi
    sleep 3
  done
  log "WARNING: some services are still initializing; their reconciliation may be deferred"
}

reconcile_sonarr_login_after_start() {
  SONARR_API_KEY=$(pull_field "Marlboro NAS - Sonarr" api_key)
  SONARR_USER=$(pull_field "Marlboro NAS - Sonarr" username)
  SONARR_PASS=$(pull_field "Marlboro NAS - Sonarr" password)
  set +e
  reconcile_sonarr_login
  local result=$?
  set -e
  case "$result" in
    0) log "Sonarr WebUI credentials already match 1Password" ;;
    1) log "Sonarr WebUI credentials reconciled from 1Password" ;;
    2) log "WARNING: Sonarr API is not ready; rerun setup later" ;;
  esac
}

start_and_reconcile_stack() {
  log "Starting the Docker stack"
  (cd "$SCRIPT_DIR" && PLEX_CLAIM="$PLEX_CLAIM_VALUE" docker compose up -d "${COMPOSE_SERVICES[@]}")
  wait_for_service_initialization
  sync_arr_api_keys
  write_env_file
  (cd "$SCRIPT_DIR" && PLEX_CLAIM="$PLEX_CLAIM_VALUE" docker compose up -d "${COMPOSE_SERVICES[@]}")
  reconcile_sonarr_login_after_start
  "$SCRIPT_DIR/setup_services.sh"
  # Keeps the Valheim world on NVMe instead of the shingled array. No-op once
  # the bind mount is in place, and it declines to touch a server with players
  # on it, so a reconcile during a session just leaves things alone.
  sudo "$SCRIPT_DIR/migrate_valheim_world.sh" \
    || warn "Valheim world storage was left on /mnt/tank — see migrate_valheim_world.sh"
  write_env_file
  if [ "${#COMPOSE_SERVICES[@]}" -eq 0 ]; then
    (cd "$SCRIPT_DIR" && docker compose up -d glance unpackerr)
  else
    (cd "$SCRIPT_DIR" && PLEX_CLAIM="$PLEX_CLAIM_VALUE" docker compose up -d "${COMPOSE_SERVICES[@]}")
  fi
}

[ "${MARLBORO_SKIP_SAMBA:-0}" = "1" ] || configure_samba
start_and_reconcile_stack
echo ""
echo "  Setup complete. .env written to: $ENV_FILE"
echo "  Tag: $TAG | Vault: $VAULT"
echo ""
if [ "$REBOOT_NEEDED" -eq 1 ]; then
  echo "  ! REBOOT REQUIRED (Sunshine): applies the sway autologin session + 'input' group."
  echo "    After reboot: finish the Sunshine web-UI setup and pair Moonlight."
  echo ""
fi
echo "  Stack started and reconciled."
