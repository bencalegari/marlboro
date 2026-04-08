#!/usr/bin/env bash
# setup.sh — Homelab credential generation and 1Password storage
# Run ONCE before `op run --env-file=.op.env -- docker compose up -d`
# Requires: 1Password CLI (op), jq, tailscale installed and authenticated

set -euo pipefail

TAG="marlboro-nas"
VAULT="Private"         # run `op vault list` to confirm your vault name

# ─── Helpers ──────────────────────────────────────────────────────────────────

log() { echo -e "\033[1;32m==>\033[0m $1" >&2; }
err() { echo -e "\033[1;31mERROR:\033[0m $1" >&2; exit 1; }

store_password() {
  local title="$1"
  local username="$2"
  local password

  if op item get "$title" --vault "$VAULT" &>/dev/null; then
    log "Item '$title' already exists in 1Password, skipping"
    password=$(op item get "$title" --vault "$VAULT" --fields password --reveal)
  else
    log "Creating '$title' in 1Password..."
    password=$(op item create \
      --category Login \
      --title "$title" \
      --vault "$VAULT" \
      --tags "$TAG" \
      --generate-password="letters,digits,32" \
      username="$username" \
      --format json | jq -r '.fields[] | select(.id=="password") | .value')
  fi

  echo "$password"
}

store_credential() {
  local title="$1"
  local username="$2"
  local password="$3"
  local url="${4:-}"

  if op item get "$title" --vault "$VAULT" &>/dev/null; then
    log "Item '$title' already exists in 1Password, skipping"
    return
  fi

  log "Storing '$title' in 1Password..."
  op item create \
    --category Login \
    --title "$title" \
    --vault "$VAULT" \
    --tags "$TAG" \
    ${url:+--url "$url"} \
    username="$username" \
    password="$password" \
    > /dev/null
}

# ─── Preflight ────────────────────────────────────────────────────────────────

command -v op &>/dev/null || err "1Password CLI (op) not found. Run Part 3 of the guide first."
command -v jq &>/dev/null || err "jq not found. Run: sudo apt install jq"
command -v tailscale &>/dev/null || err "tailscale not found. Run Part 15 of the guide first."
op whoami &>/dev/null || err "Not signed in to 1Password. Run: op signin"

log "Signed in as: $(op whoami --format=json | jq -r '.email')"
log "Generating credentials and storing in 1Password (vault: $VAULT, tag: $TAG)..."

# ─── Generate Credentials ─────────────────────────────────────────────────────

IMMICH_DB_PASSWORD=$(store_password "Marlboro NAS — Immich DB" "immich")
QBIT_PASSWORD=$(store_password "Marlboro NAS — qBittorrent" "admin")
NPM_PASSWORD=$(store_password "Marlboro NAS — Nginx Proxy Manager" "admin@example.com")
PORTAINER_PASSWORD=$(store_password "Marlboro NAS — Portainer" "admin")
ROMM_DB_PASSWORD=$(store_password "Marlboro NAS — RomM DB" "romm-user")
ROMM_ROOT_PASSWORD=$(store_password "Marlboro NAS — RomM DB Root" "root")

if ! op item get "Marlboro NAS — RomM Auth Secret" --vault "$VAULT" &>/dev/null; then
  log "Creating 'Marlboro NAS — RomM Auth Secret' in 1Password..."
  _secret=$(openssl rand -hex 32)
  op item create \
    --category Login \
    --title "Marlboro NAS — RomM Auth Secret" \
    --vault "$VAULT" \
    --tags "$TAG" \
    username="romm" \
    password="$_secret" > /dev/null
else
  log "Item 'Marlboro NAS — RomM Auth Secret' already exists in 1Password, skipping"
fi

# ─── Store Network Details ─────────────────────────────────────────────────────

if ! op item get "Marlboro NAS — Network" --vault "$VAULT" &>/dev/null; then
  log "Storing network details in 1Password..."
  op item create \
    --category "Secure Note" \
    --title "Marlboro NAS — Network" \
    --vault "$VAULT" \
    --tags "$TAG" \
    "static-ip[text]=$(ip -4 addr show enp4s0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)" \
    "tailscale-hostname[text]=$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')" \
    "tailscale-ip[text]=$(tailscale ip -4)" > /dev/null
else
  log "Item 'Marlboro NAS — Network' already exists in 1Password, skipping"
fi

# ─── Populate Bookmarks ───────────────────────────────────────────────────────

log "Populating bookmarks with network details..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATIC_IP=$(op item get "Marlboro NAS — Network" --vault "$VAULT" --fields static-ip)
TAILSCALE_HOSTNAME=$(op item get "Marlboro NAS — Network" --vault "$VAULT" --fields tailscale-hostname)

sed -i "s|<your-static-ip>|${STATIC_IP}|g" "${SCRIPT_DIR}/bookmarks.html"
sed -i "s|<your-tailscale-hostname>|${TAILSCALE_HOSTNAME}|g" "${SCRIPT_DIR}/bookmarks_tailscale.html"
log "Bookmarks populated."

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete. Credentials saved to 1Password."
echo "  Tag: $TAG | Vault: $VAULT"
echo ""
echo "  Manual steps still required:"
echo "  • qBittorrent: get temp password from logs, then:"
echo "    op item edit 'Marlboro NAS — qBittorrent' password=NEW"
echo "  • Nginx Proxy Manager: change default at :81, then:"
echo "    op item edit 'Marlboro NAS — Nginx Proxy Manager' password=NEW"
echo "  • Portainer: set password on first launch at :9000, then:"
echo "    op item edit 'Marlboro NAS — Portainer' password=NEW"
echo "  • Sunshine: set password at :47990, then:"
echo "    op item create --category Login --title 'Marlboro NAS — Sunshine'"
echo "      --vault $VAULT --tags $TAG"
echo "  • AdGuard: set password during setup wizard, then:"
echo "    op item create --category Login --title 'Marlboro NAS — AdGuard'"
echo "      --vault $VAULT --tags $TAG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log "Ready to run: op run --env-file=.op.env -- docker compose up -d"
