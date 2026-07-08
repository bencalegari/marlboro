#!/usr/bin/env bash
# setup_script.sh - Pre-compose host provisioning: credentials + .env, host-level
# setup, and the Sunshine stream-host (sway session).
# Idempotent: safe to re-run. Creates missing 1Password items, pulls values into
# .env, seeds qBittorrent/Sonarr creds, media dirs, the docker wait-for-tank drop-in,
# and provisions Sunshine (sway autologin + KMS capture — see configure_sunshine).
# Requires: 1Password CLI (op), jq. The Sunshine section additionally uses curl +
# interactive sudo (apt/gdm/usermod) and may require a reboot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
TAG="marlboro-nas"
VAULT="Private"         # run `op vault list` to confirm your vault name
REBOOT_NEEDED=0         # set by configure_sunshine (input group / gdm session); flagged in summary

# ─── Helpers ──────────────────────────────────────────────────────────────────

log() { echo -e "\033[1;32m==>\033[0m $1" >&2; }
err() { echo -e "\033[1;31mERROR:\033[0m $1" >&2; exit 1; }

# Create a Login item with a generated password if it doesn't exist
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

# Create a Login item with a specific secret (e.g. hex key) if it doesn't exist
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

# Pull a field from 1Password; returns empty string if item/field missing
pull_field() {
  local title="$1"
  local field="$2"
  op item get "$title" --vault "$VAULT" --fields "$field" --reveal 2>/dev/null || true
}

# ─── Preflight ────────────────────────────────────────────────────────────────

command -v op &>/dev/null || err "1Password CLI (op) not found."
command -v jq &>/dev/null || err "jq not found. Run: sudo apt install jq"
op whoami &>/dev/null || err "Not signed in to 1Password. Run: eval \$(op signin)"

log "Signed in as: $(op whoami --format=json | jq -r '.email')"
log "Ensuring credentials exist in 1Password (vault: $VAULT, tag: $TAG)..."

# ─── Create Missing Items ─────────────────────────────────────────────────────

ensure_password "Marlboro NAS - Immich DB"            "immich"
ensure_password "Marlboro NAS - qBittorrent"          "admin"
ensure_password "Marlboro NAS - Nginx Proxy Manager"  "admin@example.com"
ensure_password "Marlboro NAS - Portainer"            "admin"
ensure_password "Marlboro NAS - RomM DB"              "romm-user"
ensure_password "Marlboro NAS - RomM DB Root"         "root"
ensure_secret   "Marlboro NAS - RomM Auth Secret"     "romm" "$(openssl rand -hex 32)"

# Coolify — APP_KEY must be "base64:" + base64(32 bytes) (Laravel format)
ensure_secret   "Marlboro NAS - Coolify App Key"          "coolify" "base64:$(openssl rand -base64 32)"
ensure_password "Marlboro NAS - Coolify DB"               "coolify"
ensure_secret   "Marlboro NAS - Coolify Redis"            "coolify" "$(openssl rand -hex 32)"
ensure_secret   "Marlboro NAS - Coolify Pusher App ID"    "coolify" "$(openssl rand -hex 8)"
ensure_secret   "Marlboro NAS - Coolify Pusher App Key"   "coolify" "$(openssl rand -hex 16)"
ensure_secret   "Marlboro NAS - Coolify Pusher Secret"    "coolify" "$(openssl rand -hex 32)"

# Speedtest Tracker — APP_KEY must be "base64:" + base64(32 bytes) (Laravel format)
ensure_secret   "Marlboro NAS - Speedtest App Key"        "speedtest" "base64:$(openssl rand -base64 32)"

# Forgejo — admin account, created via CLI after first start (see README Part 22).
# Not consumed by the container (Forgejo generates its own SECRET_KEY on first
# run); lives in 1Password so the admin-create command can pull it.
ensure_password "Marlboro NAS - Forgejo"                  "ben"

# DuckDNS token must be created manually — just warn if missing
if ! op item get "Marlboro NAS - DuckDNS" --vault "$VAULT" &>/dev/null; then
  log "WARNING: 'Marlboro NAS - DuckDNS' not found in 1Password — DUCKDNS_TOKEN will be blank"
fi

# IGDB credentials must be created manually — just warn if missing
if ! op item get "Marlboro NAS - IGDB" --vault "$VAULT" &>/dev/null; then
  log "WARNING: 'Marlboro NAS - IGDB' not found in 1Password — IGDB vars will be blank"
fi

# ScreenScraper credentials must be created manually — just warn if missing
if ! op item get "Marlboro NAS - Screenscraper" --vault "$VAULT" &>/dev/null; then
  log "WARNING: 'Marlboro NAS - Screenscraper' not found in 1Password — SCREENSCRAPER vars will be blank"
fi

# Glance widget API keys are created manually after first-run — warn if missing.
# Note: the Sonarr/Radarr keys are also consumed by Unpackerr (archive
# extraction), so a blank key here disables auto-extraction too, not just the
# Glance widgets.
for item in "Marlboro NAS - Sonarr" "Marlboro NAS - Radarr" "Marlboro NAS - Tailscale" "Marlboro NAS - Speedtest Tracker"; do
  if ! op item get "$item" --vault "$VAULT" &>/dev/null; then
    log "WARNING: '$item' not found in 1Password — Glance widget will be blank until you add it"
  fi
done

# Glance releases widget needs a read-only GitHub PAT — warn if the 1Password item is missing.
if ! op item get "github.com" --vault "$VAULT" &>/dev/null; then
  log "WARNING: 'github.com' not found in 1Password — GITHUB_TOKEN will be blank; Glance releases widget will hit GitHub's 60/hr rate limit"
fi

# ─── Pull Credentials & Write .env ────────────────────────────────────────────

log "Pulling credentials from 1Password and writing $ENV_FILE..."

cat > "$ENV_FILE" <<EOF
# Generated by setup_script.sh — do not commit this file to git
# Credentials are stored in 1Password under tag: $TAG

IMMICH_DB_PASSWORD=$(pull_field "Marlboro NAS - Immich DB" password)
# Consumed by both qBittorrent (seeded into qBittorrent.conf below) and Flood
# (FLOOD_OPTION_qbpass), which connects to qBittorrent's Web API with auth=none.
QBIT_PASSWORD=$(pull_field "Marlboro NAS - qBittorrent" password)
# Plex one-time claim token — intentionally BLANK; not a stored secret (expires
# 4 min after issue at https://plex.tv/claim). To link the Plex server to the
# account on first start, pass it inline instead of editing this file:
#   PLEX_CLAIM=claim-xxxx docker compose up -d plex
# After the server is claimed once, blank is correct — the permanent server token
# lives in services/plex/config. Declared so compose doesn't warn on \${PLEX_CLAIM}.
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
# Consumed by both Glance (dashboard widgets) and Unpackerr (queue polling +
# archive extraction). Blank here means neither works.
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
# Consumed by the Glance "releases" widget. All tracked repos are public, so a
# read-only PAT lifts GitHub's anonymous 60/hr rate limit to 5000/hr.
GITHUB_TOKEN=$(pull_field "github.com" token)
EOF

chmod 600 "$ENV_FILE"

log ".env written with $(grep -c '=' "$ENV_FILE") variables"

# ─── Seed qBittorrent WebUI Credentials + HostHeaderValidation ───────────────
# qBittorrent stores its WebUI password as a PBKDF2-HMAC-SHA512 hash inside
# qBittorrent.conf and accepts no plaintext-password env var. We compute the
# hash from the 1Password value and write it directly, so the container never
# needs the temporary-password dance. Flood logs in with this same plaintext
# value (via FLOOD_OPTION_qbpass in .env), so the two are kept in sync here.
# We also force WebUI\HostHeaderValidation=false in the same pass — it must be
# set before first start or the API/WebUI rejects requests and the post-setup
# reconcile (setup_services.sh) can't reach qBittorrent. Runtime settings (save
# paths, share limits) are handled post-compose by setup_services.sh.

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
# HostHeaderValidation must be false or the WebUI/API rejects requests whose
# Host header isn't whitelisted — which blocks setup_services.sh on a fresh box.
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

# ─── Reconcile Sonarr WebUI Credentials ──────────────────────────────────────
# Sonarr v4 stores login creds in sonarr.db (SQLite) — no env var or config
# file path. We use the API (X-Api-Key auth, independent of forms login) to
# PUT new creds from 1Password if they've drifted. Probes a forms login first
# so we don't trigger a Sonarr restart on every setup run.

SONARR_API_KEY=$(pull_field "Marlboro NAS - Sonarr" api_key)
SONARR_USER=$(pull_field "Marlboro NAS - Sonarr" username)
SONARR_PASS=$(pull_field "Marlboro NAS - Sonarr" password)
SONARR_BASE="http://localhost:8989"

reconcile_sonarr_login() {
  # 1. API reachable?
  curl -fsS -m 5 -H "X-Api-Key: $SONARR_API_KEY" \
    "$SONARR_BASE/api/v3/system/status" >/dev/null 2>&1 || return 2

  # 2. Do current 1Password creds already work via forms login?
  #    Success → 302 to /, failure → 302 to /login?...loginFailed=true
  local redirect
  redirect=$(curl -s -o /dev/null -m 5 -w '%{redirect_url}' \
    -X POST "$SONARR_BASE/login" \
    --data-urlencode "username=$SONARR_USER" \
    --data-urlencode "password=$SONARR_PASS" \
    --data-urlencode "rememberMe=off")
  if [[ "$redirect" != *loginFailed* && -n "$redirect" ]]; then
    return 0
  fi

  # 3. Drifted — PUT new creds. Must include passwordConfirmation.
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

# ─── Ensure Media Directories & Ownership ────────────────────────────────────

MEDIA_DIRS=(/mnt/tank/media/movies /mnt/tank/media/tv /mnt/tank/downloads/complete /mnt/tank/downloads/incomplete)

if [ -d /mnt/tank ]; then
  for dir in "${MEDIA_DIRS[@]}"; do
    [ -d "$dir" ] || mkdir -p "$dir"
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

# ─── Ensure Docker Waits for /mnt/tank ───────────────────────────────────────
# Docker's data-root is /mnt/tank/docker and every service bind-mounts paths
# under /mnt/tank. If docker.service starts before the mount, it silently binds
# onto empty dirs on the root fs: imports break with phantom "not enough free
# space" errors, and downloads/media land on the root SSD where they're hidden
# (and keep consuming space) once the tank mounts over them. A RequiresMountsFor
# drop-in prevents the race — but only after a daemon-reload, so we verify the
# dependency is actually *loaded*, not merely present on disk.

DOCKER_DROPIN=/etc/systemd/system/docker.service.d/wait-for-tank.conf
DOCKER_DROPIN_CONTENT='[Unit]
RequiresMountsFor=/mnt/tank
'

# True only when docker.service has actually loaded the mount dependency.
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
  # File is correct on disk — ensure systemd has actually loaded it (a live-placed
  # drop-in stays inert until daemon-reload, even across weeks of uptime).
  if dropin_effective; then
    log "Docker wait-for-tank drop-in active"
  else
    log "Loading docker wait-for-tank drop-in (daemon-reload)..."
    sudo systemctl daemon-reload
    dropin_effective || log "WARNING: drop-in still not effective after reload — a reboot may be required"
  fi
fi

# ─── Store Network Details ─────────────────────────────────────────────────────

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

# ─── Provision the Sunshine stream host (sway session + KMS capture) ─────────
# Host-level, not a container — belongs to this pre-compose phase (no .env/container
# dependency). Runs as the normal user; uses interactive sudo for apt/gdm/usermod.
# Sets REBOOT_NEEDED (flagged in the summary). Why sway/KMS: see README Part 7.
# Idempotent: guards skip anything already in place; never clobbers a working install.
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
  SUNSHINE_VERSION="v2026.516.143833"   # pin like the rest of the stack
  DEB="sunshine-ubuntu-26.04-amd64.deb"
  DEB_URL="https://github.com/LizardByte/Sunshine/releases/download/${SUNSHINE_VERSION}/${DEB}"
  IDLE_TIMEOUT=300                       # seconds idle before the shared monitor sleeps

  log "Sunshine: provisioning stream host (sway + KMS)"
  if [ "$(id -u)" -eq 0 ]; then log "  running as root — skipping Sunshine (needs normal user for \$HOME + systemctl --user)"; return; fi
  command -v curl >/dev/null || { log "  curl not found — skipping Sunshine"; return; }
  mkdir -p "$CONF_DIR" "$SWAY_DIR" "$UNIT_DIR"

  # 1. Tear down old/broken attempts (headless-weston, AppImage, Flatpak). Do NOT
  #    touch 'sunshine.service' — on questing it's an alias of the packaged unit.
  systemctl --user disable --now weston.service 2>/dev/null || true
  if [ -f "$UNIT_DIR/sunshine.service" ] && grep -q 'sunshine.AppImage' "$UNIT_DIR/sunshine.service"; then rm -f "$UNIT_DIR/sunshine.service"; fi
  rm -f "$UNIT_DIR/weston.service"
  if flatpak list --columns=application 2>/dev/null | grep -qx dev.lizardbyte.app.Sunshine; then
    log "  removing Flatpak Sunshine (can't KMS-capture)…"; sudo flatpak uninstall -y --system dev.lizardbyte.app.Sunshine
  fi

  # 2. Packages: sway session + swayidle + retroarch + icon converter.
  PKGS=()
  command -v sway         >/dev/null || PKGS+=(sway)
  command -v swayidle     >/dev/null || PKGS+=(swayidle)
  command -v retroarch    >/dev/null || PKGS+=(retroarch)
  command -v rsvg-convert >/dev/null || PKGS+=(librsvg2-bin)
  if [ "${#PKGS[@]}" -gt 0 ]; then log "  installing: ${PKGS[*]}…"; sudo apt-get update -qq; sudo apt-get install -y "${PKGS[@]}"; fi

  # 3. Sunshine .deb (postinst setcaps the binary for KMS).
  if ! dpkg-query -W sunshine >/dev/null 2>&1; then
    log "  installing $DEB ($SUNSHINE_VERSION)…"
    tmp="$(mktemp -d)"
    if ! curl -fL "$DEB_URL" -o "$tmp/$DEB"; then log "  ERROR: download failed: $DEB_URL — skipping Sunshine"; rm -rf "$tmp"; return; fi
    sudo apt-get install -y "$tmp/$DEB"; rm -rf "$tmp"
  else
    log "  sunshine already installed (dpkg $(dpkg-query -W -f='${Version}' sunshine))"
  fi
  getcap /usr/bin/sunshine 2>/dev/null | grep -q cap_sys_admin || log "  WARNING: /usr/bin/sunshine missing cap_sys_admin — KMS capture will fail (reinstall the .deb)"

  # 4. 'input' group for uinput (virtual gamepad/keyboard/mouse).
  if ! id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx input; then log "  adding $USER_NAME to 'input' group…"; sudo usermod -aG input "$USER_NAME"; REBOOT_NEEDED=1; fi

  # 5. GDM autologin into the sway session (GDM reads Session= from AccountsService).
  if [ -f "$GDM_CONF" ] && ! grep -qE '^\s*AutomaticLoginEnable\s*=\s*[Tt]rue' "$GDM_CONF"; then
    log "  enabling GDM autologin for $USER_NAME…"
    sudo sed -i -E "/^\[daemon\]/a AutomaticLoginEnable=True\nAutomaticLogin=$USER_NAME" "$GDM_CONF"; REBOOT_NEEDED=1
  fi
  if ! sudo grep -qE '^\s*Session\s*=\s*sway' "$AS_FILE" 2>/dev/null; then
    log "  setting autologin session -> sway…"
    sudo python3 - "$AS_FILE" <<'PY'
import configparser, os, sys
p = sys.argv[1]
c = configparser.ConfigParser(); c.optionxform = str  # preserve key case, don't clobber existing keys
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

  # 6. sway session config + sway-session.target. graphical-session.target has
  #    RefuseManualStart=yes, so it's pulled in via this target's BindsTo (which
  #    is what actually launches Sunshine on the sway session).
  log "  writing sway config + sway-session.target…"
  cat > "$SWAY_DIR/config" <<'EOF'
# stream-host session (autologin target for Sunshine/Moonlight)
include /etc/sway/config

exec systemctl --user import-environment WAYLAND_DISPLAY DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP && \
     dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP=sway && \
     systemctl --user start sway-session.target

# Lit at boot; swayidle blanks it after inactivity (see swayidle.service).
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

  # 7. Shared-monitor power control: display.sh drives DPMS via swaymsg; swayidle
  #    blanks on idle; Sunshine's global_prep_cmd forces the display on + pauses the
  #    blanker for the duration of a stream (so KMS capture always has a lit connector).
  log "  writing display.sh + swayidle.service (idle ${IDLE_TIMEOUT}s)…"
  cat > "$CONF_DIR/display.sh" <<'EOF'
#!/bin/bash
# Shared-monitor power control for the Sunshine stream host.
#   blank / wake              - idle blanker off/on (driven by swayidle)
#   stream-start / stream-end - Sunshine prep: force on + pause blanker / re-arm blanker
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

  # 8. RetroArch tile icon (rendered from the shipped SVG; generic fallback).
  ICON="$CONF_DIR/retroarch.png"
  RA_SVG="/usr/share/icons/hicolor/scalable/apps/com.libretro.RetroArch.svg"
  if [ ! -f "$ICON" ]; then
    if command -v rsvg-convert >/dev/null && [ -f "$RA_SVG" ]; then log "  rendering RetroArch icon…"; rsvg-convert -w 256 -h 256 "$RA_SVG" -o "$ICON"
    elif [ -f /usr/share/sunshine/box.png ]; then cp /usr/share/sunshine/box.png "$ICON"; fi
  fi

  # 9. sunshine.conf: KMS + VAAPI + auto-detected CSRF origins + wake-on-stream.
  #    csrf_allowed_origins must list every IP the web UI is reached by (browser
  #    Origin includes :47990). Rewrite only if absent/stale (never clobber a working conf).
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
origin_web_ui_allowed = lan
csrf_allowed_origins = $ORIGINS
global_prep_cmd = [{"do":"$CONF_DIR/display.sh stream-start","undo":"$CONF_DIR/display.sh stream-end","elevated":"false"}]
EOF
    sed -i '/^csrf_allowed_origins = *$/d' "$CONF_DIR/sunshine.conf"   # drop if no IPs detected
  fi

  # 10. apps.json — seed only if absent (web UI manages it after first run).
  #     RetroArch uses cmd + auto-detach:false so it QUITS when the stream ends.
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

  # 10.5 Seed the web-UI login from 1Password (first run only). Sunshine hashes the
  #      password itself via `--creds` (its scheme is internal/version-specific — we
  #      never reproduce it) and MERGES, so existing Moonlight pairings survive.
  #      Skipped once creds exist, so re-runs don't reset the salt or bounce the service.
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

  # 11. Enable the user services (start inside the sway session after reboot).
  systemctl --user daemon-reload
  systemctl --user enable app-dev.lizardbyte.app.Sunshine.service >/dev/null 2>&1 || true
  systemctl --user enable swayidle.service >/dev/null 2>&1 || true
  log "  Sunshine provisioned (services enabled; start on next sway session)"
}
configure_sunshine

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete. .env written to: $ENV_FILE"
echo "  Tag: $TAG | Vault: $VAULT"
echo ""
if [ "$REBOOT_NEEDED" -eq 1 ]; then
  echo "  ! REBOOT REQUIRED (Sunshine): applies the sway autologin session + 'input' group."
  echo "    After reboot: one-time Sunshine web-UI wizard + Moonlight pairing — README Part 7."
  echo ""
fi
echo "  Ready to run: docker compose up -d"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
