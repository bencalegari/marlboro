#!/usr/bin/env bash
# setup_proxy_hosts.sh — Reconcile Nginx Proxy Manager proxy hosts + their
# Let's Encrypt certs (DNS-01 via DuckDNS) from a declarative list below.
# Idempotent: creates any missing cert + proxy host, skips ones that already
# exist. Never edits or deletes existing hosts (so manual tweaks survive).
#
# This is a POST-setup step: run it AFTER `docker compose up -d`. NPM must be up
# on :81 and DuckDNS reachable (cert issuance uses a DNS-01 challenge). The NPM
# web UI does exactly this — the script just makes the proxy topology
# reproducible from the repo instead of hand-clicked.
#
# Reads NGINX_EMAIL_ID / NGINX_PASSWORD / DUCKDNS_TOKEN from .env (written by
# setup_script.sh). Requires: curl, jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
NPM="http://localhost:81"

log()  { echo -e "\033[1;32m==>\033[0m $1" >&2; }
warn() { echo -e "\033[1;33mWARNING:\033[0m $1" >&2; }
err()  { echo -e "\033[1;31mERROR:\033[0m $1" >&2; exit 1; }

# ─── Desired Proxy Hosts ──────────────────────────────────────────────────────
# Format: domain | forward_host | forward_port | websockets | ssl_forced
# Host-networked / host-published services (Jellyfin, Plex, Coolify, the apex)
# are reached via the LAN IP; services on the homelab bridge are reached by
# container name. This mirrors what's deployed — keep it in sync when adding a
# service that should be exposed externally.
HOSTS=(
  "marlboro-bc.duckdns.org|192.168.0.10|8096|true|true"        # apex → Jellyfin
  "jellyfin.marlboro-bc.duckdns.org|192.168.0.10|8096|true|false"
  "plex.marlboro-bc.duckdns.org|192.168.0.10|32400|true|true"
  "seerr.marlboro-bc.duckdns.org|seerr|5055|true|false"
  "git.marlboro-bc.duckdns.org|forgejo|3000|true|false"
  "coolify.marlboro-bc.duckdns.org|192.168.0.10|8000|true|true"
)

# ─── Preflight ────────────────────────────────────────────────────────────────

command -v jq   &>/dev/null || err "jq not found. Run: sudo apt install jq"
command -v curl &>/dev/null || err "curl not found."
[ -f "$ENV_FILE" ] || err ".env not found — run setup_script.sh first."

getenv() { grep -E "^$1=" "$ENV_FILE" | cut -d= -f2-; }
EMAIL=$(getenv NGINX_EMAIL_ID)
PASS=$(getenv NGINX_PASSWORD)
DUCK=$(getenv DUCKDNS_TOKEN)
[ -n "$EMAIL" ] && [ -n "$PASS" ] || err "NGINX_EMAIL_ID / NGINX_PASSWORD missing in .env"

curl -fsS -m5 "$NPM/api/" >/dev/null 2>&1 \
  || err "NPM not reachable at $NPM — start it first: docker compose up -d nginx-proxy-manager"

TOKEN=$(curl -s -m10 -X POST "$NPM/api/tokens" -H 'Content-Type: application/json' \
  -d "{\"identity\":\"$EMAIL\",\"secret\":\"$PASS\"}" | jq -r '.token // empty')
[ -n "$TOKEN" ] || err "Failed to get NPM API token — check NGINX_EMAIL_ID/NGINX_PASSWORD in .env."
AUTH=(-H "Authorization: Bearer $TOKEN")

# ─── Current State (fetched once; certs refreshed after each new issuance) ─────

CERTS=$(curl -s -m10 "${AUTH[@]}" "$NPM/api/nginx/certificates")
PHOSTS=$(curl -s -m10 "${AUTH[@]}" "$NPM/api/nginx/proxy-hosts")

cert_id_for() { echo "$CERTS" | jq -r --arg d "$1" '[.[]|select(.domain_names|index($d))][0].id // empty'; }
host_exists() { echo "$PHOSTS" | jq -e --arg d "$1" 'any(.[]; .domain_names|index($d))' >/dev/null; }

# Echo an existing cert id for the domain, or request a new DNS-01 cert and echo
# its id. Echoes empty string on failure (caller decides what to do).
ensure_cert() {
  local domain="$1" id body resp
  id=$(cert_id_for "$domain")
  if [ -n "$id" ]; then echo "$id"; return; fi
  if [ -z "$DUCK" ]; then warn "No cert for $domain and DUCKDNS_TOKEN is blank — skipping"; echo ""; return; fi
  log "Requesting DNS-01 cert for $domain (~30-90s)..."
  body=$(jq -n --arg d "$domain" --arg cred "dns_duckdns_token=$DUCK" \
    '{provider:"letsencrypt",domain_names:[$d],meta:{dns_challenge:true,dns_provider:"duckdns",dns_provider_credentials:$cred}}')
  resp=$(curl -s -m180 -X POST "$NPM/api/nginx/certificates" "${AUTH[@]}" -H 'Content-Type: application/json' -d "$body")
  id=$(echo "$resp" | jq -r '.id // empty')
  if [ -z "$id" ]; then warn "Cert request for $domain failed: $(echo "$resp" | jq -c '.error // .')"; echo ""; return; fi
  CERTS=$(curl -s -m10 "${AUTH[@]}" "$NPM/api/nginx/certificates")  # refresh cache
  echo "$id"
}

# ─── Reconcile ────────────────────────────────────────────────────────────────

fails=0
for row in "${HOSTS[@]}"; do
  IFS='|' read -r domain fhost fport ws sslf <<<"$row"

  if host_exists "$domain"; then
    log "Proxy host '$domain' exists — skipping"
    continue
  fi

  cid=$(ensure_cert "$domain")
  if [ -z "$cid" ]; then warn "Skipping '$domain' — no certificate"; fails=$((fails+1)); continue; fi

  body=$(jq -n --arg d "$domain" --arg fh "$fhost" --argjson fp "$fport" \
    --argjson ws "$ws" --argjson sslf "$sslf" --argjson cid "$cid" \
    '{domain_names:[$d],forward_scheme:"http",forward_host:$fh,forward_port:$fp,
      certificate_id:$cid,ssl_forced:$sslf,http2_support:true,
      allow_websocket_upgrade:$ws,block_exploits:true,caching_enabled:false,
      hsts_enabled:false,hsts_subdomains:false,access_list_id:0,
      advanced_config:"",locations:[],meta:{}}')
  resp=$(curl -s -m15 -X POST "$NPM/api/nginx/proxy-hosts" "${AUTH[@]}" -H 'Content-Type: application/json' -d "$body")
  if echo "$resp" | jq -e '.id' >/dev/null 2>&1; then
    log "Created proxy host '$domain' → $fhost:$fport (cert $cid)"
  else
    warn "Failed to create proxy host '$domain': $(echo "$resp" | jq -c '.error // .')"
    fails=$((fails+1))
  fi
done

if [ "$fails" -gt 0 ]; then
  err "Proxy host reconcile finished with $fails failure(s) — see warnings above."
fi
log "Proxy host reconcile complete."
