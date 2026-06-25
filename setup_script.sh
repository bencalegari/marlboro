#!/usr/bin/env bash
# setup.sh - Homelab credential generation, 1Password storage, and .env sync
# Idempotent: safe to re-run. Creates missing 1Password items, then pulls all
# values and writes .env. Requires: 1Password CLI (op), jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
TAG="marlboro-nas"
VAULT="Private"         # run `op vault list` to confirm your vault name

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

# Glance widget API keys are created manually after first-run — warn if missing
for item in "Marlboro NAS - Sonarr" "Marlboro NAS - Radarr" "Marlboro NAS - Tailscale" "Marlboro NAS - Speedtest Tracker"; do
  if ! op item get "$item" --vault "$VAULT" &>/dev/null; then
    log "WARNING: '$item' not found in 1Password — Glance widget will be blank until you add it"
  fi
done

# ─── Pull Credentials & Write .env ────────────────────────────────────────────

log "Pulling credentials from 1Password and writing $ENV_FILE..."

cat > "$ENV_FILE" <<EOF
# Generated by setup_script.sh — do not commit this file to git
# Credentials are stored in 1Password under tag: $TAG

IMMICH_DB_PASSWORD=$(pull_field "Marlboro NAS - Immich DB" password)
# Consumed by both qBittorrent (seeded into qBittorrent.conf below) and Flood
# (FLOOD_OPTION_qbpass), which connects to qBittorrent's Web API with auth=none.
QBIT_PASSWORD=$(pull_field "Marlboro NAS - qBittorrent" password)
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
EOF

chmod 600 "$ENV_FILE"

log ".env written with $(grep -c '=' "$ENV_FILE") variables"

# ─── Seed qBittorrent WebUI Credentials ──────────────────────────────────────
# qBittorrent stores its WebUI password as a PBKDF2-HMAC-SHA512 hash inside
# qBittorrent.conf and accepts no plaintext-password env var. We compute the
# hash from the 1Password value and write it directly, so the container never
# needs the temporary-password dance. Flood logs in with this same plaintext
# value (via FLOOD_OPTION_qbpass in .env), so the two are kept in sync here.

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
prefs_idx = next((i for i, l in enumerate(lines) if l.strip() == '[Preferences]'), None)

pw_ok = pw_idx is not None and verify(password, lines[pw_idx])
user_ok = user_idx is not None and lines[user_idx] == 'WebUI\\Username=admin'

if pw_ok and user_ok:
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

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete. .env written to: $ENV_FILE"
echo "  Tag: $TAG | Vault: $VAULT"
echo ""
echo "  Ready to run: docker compose up -d"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
