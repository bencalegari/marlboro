#!/usr/bin/env bash
# setup_services.sh — Reconcile in-app settings across the stack from the repo.
# Idempotent: creates/converges what's missing or drifted, skips what already
# matches. Never deletes user-added config (so manual tweaks survive).
#
# POST-setup step: run AFTER `docker compose up -d`. The apps must be up on
# their ports. Same philosophy as setup_script.sh: make the hand-clicked wiring
# reproducible from the repo. (Absorbed the former setup_proxy_hosts.sh.)
#
# What it configures (all self-contained — keys read from .env / each app's own
# config file, no new 1Password items):
#   qBittorrent  — seeding share limits (ratio 1.0 / 336h → remove+delete)
#   Sonarr/Radarr— download client, root folder, and applies the tracked
#                  services/<app>/settings/*.json (quality profile "Any",
#                  naming, media management, delay profile)
#   Prowlarr     — Sonarr/Radarr applications + FlareSolverr indexer proxy
#   AdGuard      — upstream DNS, rate limit, DNS blocklists (sudo yaml reconcile)
#   NginxProxyMgr— proxy hosts + Let's Encrypt certs (DNS-01 via DuckDNS) from
#                  the declarative HOSTS list below
#
# Requires: curl, jq, python3. Reads .env (written by setup_script.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

log()  { echo -e "\033[1;32m==>\033[0m $1" >&2; }
warn() { echo -e "\033[1;33mWARNING:\033[0m $1" >&2; }
err()  { echo -e "\033[1;31mERROR:\033[0m $1" >&2; exit 1; }

# ─── Endpoints (host-side) ──────────────────────────────────────────────────
SONARR=http://localhost:8989
RADARR=http://localhost:7878
PROWLARR=http://localhost:9696
QBIT=http://localhost:8181
NPM=http://localhost:81
# Container-network coordinates the *arr apps use to reach each other:
QBIT_HOST=qbittorrent; QBIT_PORT=8080

# ─── Preflight ──────────────────────────────────────────────────────────────
for bin in curl jq python3; do command -v "$bin" &>/dev/null || err "$bin not found."; done
[ -f "$ENV_FILE" ] || err ".env not found — run setup_script.sh first."

getenv() { grep -E "^$1=" "$ENV_FILE" | cut -d= -f2-; }
SONARR_KEY=$(getenv SONARR_API_KEY)
RADARR_KEY=$(getenv RADARR_API_KEY)
QBIT_PW=$(getenv QBIT_PASSWORD)

# Prowlarr key lives in its own config.xml.
PROWLARR_KEY=$(grep -oE '<ApiKey>[^<]+' "$SCRIPT_DIR/services/prowlarr/config/config.xml" 2>/dev/null | sed 's/<ApiKey>//' || true)

# up() — is an app reachable? arg1=base url, arg2=header (may be empty)
up() { curl -fsS -m5 ${2:+-H "$2"} "$1" >/dev/null 2>&1; }

# ─── qBittorrent: seeding share limits ───────────────────────────────────────
# Adhere to tracker rule: seed to ratio 1.0 OR 336h, whichever first, then
# remove the torrent + delete its files (safe — imports are hardlinks).
configure_qbit() {
  log "qBittorrent: seeding share limits"
  [ -n "$QBIT_PW" ] || { warn "QBIT_PASSWORD blank — skipping qBit"; return; }
  local cj; cj=$(mktemp); trap 'rm -f "$cj"' RETURN
  if ! curl -fsS -m10 -c "$cj" -o /dev/null \
        --data-urlencode "username=admin" --data-urlencode "password=$QBIT_PW" \
        -H "Referer: $QBIT" "$QBIT/api/v2/auth/login" 2>/dev/null; then
    warn "qBittorrent unreachable/login failed on :8181 — skipping"; return
  fi
  # Save paths + seeding share limits (ratio 1.0 / 336h → remove+delete files).
  local desired='{"save_path":"/data/downloads/complete","temp_path_enabled":true,"temp_path":"/data/downloads/incomplete","max_ratio_enabled":true,"max_ratio":1,"max_seeding_time_enabled":true,"max_seeding_time":20160,"max_ratio_act":2}'
  # Converge only if drifted (keeps the run quiet + avoids needless writes).
  local cur
  cur=$(curl -s -m10 -b "$cj" -H "Referer: $QBIT" "$QBIT/api/v2/app/preferences")
  if echo "$cur" | jq -e '
        .save_path=="/data/downloads/complete" and .temp_path_enabled==true and .temp_path=="/data/downloads/incomplete"
        and .max_ratio_enabled==true and .max_ratio==1 and .max_seeding_time_enabled==true
        and .max_seeding_time==20160 and .max_ratio_act==2' >/dev/null 2>&1; then
    log "  save paths + share limits already set"
  else
    curl -fsS -m10 -b "$cj" -H "Referer: $QBIT" \
      --data-urlencode "json=$desired" "$QBIT/api/v2/app/setPreferences" >/dev/null
    log "  save paths + share limits applied (ratio 1.0 / 336h / remove+delete)"
  fi
}

# ─── *arr generic helpers ────────────────────────────────────────────────────
arr_get() { curl -fsS -m10 -H "X-Api-Key: $2" "$1$3"; }
arr_post(){ curl -fsS -m15 -X POST -H "X-Api-Key: $2" -H 'Content-Type: application/json' --data-binary "$4" "$1$3"; }
arr_put() { curl -fsS -m15 -X PUT  -H "X-Api-Key: $2" -H 'Content-Type: application/json' --data-binary "$4" "$1$3"; }

# Ensure a qBittorrent download client exists (create from schema if missing).
ensure_download_client() {
  local base="$1" key="$2" category="$3"
  if arr_get "$base" "$key" "/api/v3/downloadclient" | jq -e 'any(.[]; .implementation=="QBittorrent")' >/dev/null; then
    log "  download client (qBittorrent) exists"; return
  fi
  local body
  body=$(arr_get "$base" "$key" "/api/v3/downloadclient/schema" \
    | jq --arg h "$QBIT_HOST" --argjson p "$QBIT_PORT" --arg c "$category" --arg pw "$QBIT_PW" '
        (.[] | select(.implementation=="QBittorrent")) as $s
        | $s
        | .enable=true | .name="qBittorrent"
        | .fields = ([ .fields[]
            | if .name=="host" then .value=$h
              elif .name=="port" then .value=$p
              elif .name=="username" then .value="admin"
              elif .name=="password" then .value=$pw
              elif (.name|test("[Cc]ategory")) then .value=$c
              else . end ])')
  arr_post "$base" "$key" "/api/v3/downloadclient" "$body" >/dev/null \
    && log "  download client (qBittorrent, category=$category) created" \
    || warn "  failed to create download client"
}

ensure_root_folder() {
  local base="$1" key="$2" path="$3"
  if arr_get "$base" "$key" "/api/v3/rootfolder" | jq -e --arg p "$path" 'any(.[]; .path==$p)' >/dev/null; then
    log "  root folder $path exists"
  else
    arr_post "$base" "$key" "/api/v3/rootfolder" "$(jq -n --arg p "$path" '{path:$p}')" >/dev/null \
      && log "  root folder $path created" || warn "  failed to add root folder $path"
  fi
}

# Apply a tracked settings JSON (singleton config endpoints) if present.
apply_settings_json() {
  local base="$1" key="$2" endpoint="$3" file="$4"
  [ -f "$file" ] || { warn "  $file missing — skipping"; return; }
  arr_put "$base" "$key" "$endpoint" "@$file" >/dev/null 2>&1 \
    && log "  applied $(basename "$file")" || warn "  failed applying $(basename "$file")"
}

configure_arr() {
  local name="$1" base="$2" key="$3" category="$4" rootpath="$5" sdir="$6"
  log "$name: download client, root folder, tracked settings"
  [ -n "$key" ] || { warn "  $name API key blank — skipping"; return; }
  up "$base/api/v3/system/status" "X-Api-Key: $key" || { warn "  $name unreachable — skipping"; return; }
  ensure_download_client "$base" "$key" "$category"
  ensure_root_folder     "$base" "$key" "$rootpath"
  # Singleton configs: PUT the exported object straight back (converges).
  apply_settings_json "$base" "$key" "/api/v3/config/naming"          "$sdir/naming.json"
  apply_settings_json "$base" "$key" "/api/v3/config/mediamanagement" "$sdir/mediamanagement.json"
  # Quality profile "Any" (id in the file) + delay profile (list → id 1).
  if [ -f "$sdir/quality-profile-any.json" ]; then
    local qpid; qpid=$(jq -r '.id' "$sdir/quality-profile-any.json")
    arr_put "$base" "$key" "/api/v3/qualityprofile/$qpid" "@$sdir/quality-profile-any.json" >/dev/null 2>&1 \
      && log "  applied quality-profile-any.json" || warn "  failed applying quality profile"
  fi
  if [ -f "$sdir/delayprofile.json" ]; then
    local dp; dp=$(mktemp)
    jq '.[0]' "$sdir/delayprofile.json" > "$dp"
    local dpid; dpid=$(jq -r '.id' "$dp")
    arr_put "$base" "$key" "/api/v3/delayprofile/$dpid" "@$dp" >/dev/null 2>&1 \
      && log "  applied delayprofile.json" || warn "  failed applying delay profile"
    rm -f "$dp"
  fi
}

# ─── Prowlarr: apps + FlareSolverr proxy ─────────────────────────────────────
ensure_prowlarr_app() {
  local appname="$1" syncbase="$2" appkey="$3"
  if arr_get "$PROWLARR" "$PROWLARR_KEY" "/api/v1/applications" | jq -e --arg n "$appname" 'any(.[]; .name==$n)' >/dev/null; then
    log "  application $appname exists"; return
  fi
  [ -n "$appkey" ] || { warn "  $appname API key blank — skipping app link"; return; }
  local impl; impl=$appname   # implementation name matches (Sonarr/Radarr)
  local body
  body=$(arr_get "$PROWLARR" "$PROWLARR_KEY" "/api/v1/applications/schema" \
    | jq --arg n "$appname" --arg impl "$impl" --arg base "$syncbase" --arg k "$appkey" '
        (.[] | select(.implementation==$impl)) as $s
        | $s | .name=$n | .syncLevel="fullSync"
        | .fields = ([ .fields[]
            | if .name=="prowlarrUrl" then .value="http://prowlarr:9696"
              elif .name=="baseUrl" then .value=$base
              elif .name=="apiKey" then .value=$k
              else . end ])')
  arr_post "$PROWLARR" "$PROWLARR_KEY" "/api/v1/applications" "$body" >/dev/null \
    && log "  application $appname created" || warn "  failed to create application $appname"
}

ensure_flaresolverr() {
  if arr_get "$PROWLARR" "$PROWLARR_KEY" "/api/v1/indexerproxy" | jq -e 'any(.[]; .implementation=="FlareSolverr")' >/dev/null; then
    log "  FlareSolverr proxy exists"; return
  fi
  local body
  body=$(arr_get "$PROWLARR" "$PROWLARR_KEY" "/api/v1/indexerproxy/schema" \
    | jq '(.[] | select(.implementation=="FlareSolverr")) as $s
          | $s | .name="FlareSolverr"
          | .fields = ([ .fields[] | if .name=="host" then .value="http://flaresolverr:8191" else . end ])
          | .tags=[]')
  arr_post "$PROWLARR" "$PROWLARR_KEY" "/api/v1/indexerproxy" "$body" >/dev/null \
    && log "  FlareSolverr proxy created" || warn "  failed to create FlareSolverr proxy"
}

configure_prowlarr() {
  log "Prowlarr: applications + FlareSolverr proxy"
  [ -n "$PROWLARR_KEY" ] || { warn "  Prowlarr API key not found in config.xml — skipping"; return; }
  up "$PROWLARR/api/v1/system/status" "X-Api-Key: $PROWLARR_KEY" || { warn "  Prowlarr unreachable — skipping"; return; }
  ensure_flaresolverr
  ensure_prowlarr_app "Radarr" "http://radarr:7878" "$RADARR_KEY"
  ensure_prowlarr_app "Sonarr" "http://sonarr:8989" "$SONARR_KEY"
}

# NOTE: Profilarr is intentionally NOT reconciled here. v1 exposed a REST API
# (/api/arr/config) that this script used to clear synced profiles; Profilarr v2
# is a SvelteKit app with no such API and an opt-in sync model (nothing syncs
# unless selected), so the old resurrect-prevention hack is obsolete. Manage
# profile/CF sync in the Profilarr UI. See README "Profilarr".

# ─── AdGuard: upstream DNS, rate limit, blocklists ───────────────────────────
# AdGuardHome.yaml is root-owned and AdGuard has no stored API creds here, so we
# reconcile the yaml directly (needs sudo) and restart. Degrades gracefully:
# prints the manual steps if sudo or PyYAML is unavailable.
AG_YAML="$SCRIPT_DIR/services/adguard/conf/AdGuardHome.yaml"
configure_adguard() {
  log "AdGuard: upstream DNS, rate limit, blocklists"
  if ! sudo -n true 2>/dev/null; then
    warn "  passwordless sudo unavailable — set these manually in the AdGuard UI:"
    echo  "    Upstream DNS: add https://dns.cloudflare.com/dns-query" >&2
    echo  "    Rate limit: 300 (or 0)" >&2
    echo  "    Blocklists: EasyList, EasyPrivacy, Steven Black's Hosts" >&2
    return
  fi
  if ! python3 -c 'import yaml' 2>/dev/null; then
    warn "  PyYAML not installed (pip install pyyaml) — skipping AdGuard reconcile"; return
  fi
  local changed
  changed=$(sudo python3 - "$AG_YAML" <<'PY'
import sys, yaml
p = sys.argv[1]
with open(p) as f: cfg = yaml.safe_load(f) or {}
dns = cfg.setdefault('dns', {})
changed = False
# upstream DNS
ups = dns.setdefault('upstream_dns', [])
cf = 'https://dns.cloudflare.com/dns-query'
if cf not in ups:
    ups.append(cf); changed = True
# rate limit
if dns.get('ratelimit') != 300:
    dns['ratelimit'] = 300; changed = True
# blocklists
want = {
    'https://easylist.to/easylist/easylist.txt': 'EasyList',
    'https://easylist.to/easylist/easyprivacy.txt': 'EasyPrivacy',
    'https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts': "Steven Black's Hosts",
}
filters = cfg.setdefault('filters', [])
have = {f.get('url') for f in filters}
next_id = (max([f.get('id', 0) for f in filters], default=0)) + 1
for url, name in want.items():
    if url not in have:
        filters.append({'enabled': True, 'url': url, 'name': name, 'id': next_id}); next_id += 1; changed = True
# Local DNS rewrites so bare hostnames resolve to the NAS on the LAN
# (e.g. \\marlboro / smb://marlboro for SMB — see Part 17.8).
rewrites = cfg.setdefault('filtering', {}).setdefault('rewrites', [])
want_rewrites = [{'domain': 'marlboro', 'answer': '192.168.0.10', 'enabled': True}]
for rw in want_rewrites:
    if rw not in rewrites:
        rewrites.append(rw); changed = True
if changed:
    with open(p, 'w') as f: yaml.safe_dump(cfg, f, sort_keys=False, default_flow_style=False)
print('changed' if changed else 'unchanged')
PY
)
  if [ "$changed" = "changed" ]; then
    (cd "$SCRIPT_DIR" && docker compose restart adguard >/dev/null 2>&1) || true
    log "  AdGuard settings reconciled (restarted)"
  else
    log "  AdGuard settings already match"
  fi
}

# ─── Nginx Proxy Manager: proxy hosts + Let's Encrypt certs ──────────────────
# Reconcile proxy hosts + their DNS-01 (DuckDNS) certs from the declarative list.
# Creates missing cert + host, skips existing (manual tweaks survive). NPM must
# be up on :81 with its admin creds set; cert issuance needs DuckDNS reachable.
#
# Format: domain | forward_host | forward_port | websockets | ssl_forced
# Host-networked / host-published services (Jellyfin, Plex, Coolify, the apex)
# are reached via the LAN IP; bridge services by container name. Keep in sync
# when exposing a new service externally.
NPM_HOSTS=(
  "marlboro-bc.duckdns.org|192.168.0.10|8096|true|true"        # apex → Jellyfin
  "jellyfin.marlboro-bc.duckdns.org|192.168.0.10|8096|true|false"
  "plex.marlboro-bc.duckdns.org|192.168.0.10|32400|true|true"
  "seerr.marlboro-bc.duckdns.org|seerr|5055|true|false"
  "git.marlboro-bc.duckdns.org|forgejo|3000|true|false"
  "coolify.marlboro-bc.duckdns.org|192.168.0.10|8000|true|true"
)

# Helpers use script-level NPM_AUTH / NPM_CERTS / NPM_PHOSTS set in configure_proxy_hosts.
npm_cert_id_for() { echo "$NPM_CERTS" | jq -r --arg d "$1" '[.[]|select(.domain_names|index($d))][0].id // empty'; }
npm_host_exists() { echo "$NPM_PHOSTS" | jq -e --arg d "$1" 'any(.[]; .domain_names|index($d))' >/dev/null; }

# Echo an existing cert id for the domain, or request a new DNS-01 cert and echo
# its id. Echoes empty string on failure (caller decides what to do).
npm_ensure_cert() {
  local domain="$1" id body resp
  id=$(npm_cert_id_for "$domain")
  if [ -n "$id" ]; then echo "$id"; return; fi
  if [ -z "$NPM_DUCK" ]; then warn "  no cert for $domain and DUCKDNS_TOKEN blank — skipping"; echo ""; return; fi
  log "  requesting DNS-01 cert for $domain (~30-90s)..."
  body=$(jq -n --arg d "$domain" --arg cred "dns_duckdns_token=$NPM_DUCK" \
    '{provider:"letsencrypt",domain_names:[$d],meta:{dns_challenge:true,dns_provider:"duckdns",dns_provider_credentials:$cred}}')
  resp=$(curl -s -m180 -X POST "$NPM/api/nginx/certificates" "${NPM_AUTH[@]}" -H 'Content-Type: application/json' -d "$body")
  id=$(echo "$resp" | jq -r '.id // empty')
  if [ -z "$id" ]; then warn "  cert request for $domain failed: $(echo "$resp" | jq -c '.error // .')"; echo ""; return; fi
  NPM_CERTS=$(curl -s -m10 "${NPM_AUTH[@]}" "$NPM/api/nginx/certificates")  # refresh cache
  echo "$id"
}

configure_proxy_hosts() {
  log "Nginx Proxy Manager: proxy hosts + certs"
  local email pass; email=$(getenv NGINX_EMAIL_ID); pass=$(getenv NGINX_PASSWORD); NPM_DUCK=$(getenv DUCKDNS_TOKEN)
  [ -n "$email" ] && [ -n "$pass" ] || { warn "  NGINX_EMAIL_ID/NGINX_PASSWORD missing in .env — skipping"; return; }
  curl -fsS -m5 "$NPM/api/" >/dev/null 2>&1 || { warn "  NPM unreachable at :81 — skipping"; return; }
  local token
  token=$(curl -s -m10 -X POST "$NPM/api/tokens" -H 'Content-Type: application/json' \
    -d "{\"identity\":\"$email\",\"secret\":\"$pass\"}" | jq -r '.token // empty')
  [ -n "$token" ] || { warn "  NPM token failed — check NGINX_EMAIL_ID/NGINX_PASSWORD — skipping"; return; }
  NPM_AUTH=(-H "Authorization: Bearer $token")
  NPM_CERTS=$(curl -s -m10 "${NPM_AUTH[@]}" "$NPM/api/nginx/certificates")
  NPM_PHOSTS=$(curl -s -m10 "${NPM_AUTH[@]}" "$NPM/api/nginx/proxy-hosts")

  local fails=0 row domain fhost fport ws sslf cid body resp
  for row in "${NPM_HOSTS[@]}"; do
    IFS='|' read -r domain fhost fport ws sslf <<<"$row"
    if npm_host_exists "$domain"; then log "  proxy host $domain exists"; continue; fi
    cid=$(npm_ensure_cert "$domain")
    [ -n "$cid" ] || { warn "  skipping $domain — no certificate"; fails=$((fails+1)); continue; }
    body=$(jq -n --arg d "$domain" --arg fh "$fhost" --argjson fp "$fport" \
      --argjson ws "$ws" --argjson sslf "$sslf" --argjson cid "$cid" \
      '{domain_names:[$d],forward_scheme:"http",forward_host:$fh,forward_port:$fp,
        certificate_id:$cid,ssl_forced:$sslf,http2_support:true,
        allow_websocket_upgrade:$ws,block_exploits:true,caching_enabled:false,
        hsts_enabled:false,hsts_subdomains:false,access_list_id:0,
        advanced_config:"",locations:[],meta:{}}')
    resp=$(curl -s -m15 -X POST "$NPM/api/nginx/proxy-hosts" "${NPM_AUTH[@]}" -H 'Content-Type: application/json' -d "$body")
    if echo "$resp" | jq -e '.id' >/dev/null 2>&1; then
      log "  created proxy host $domain → $fhost:$fport (cert $cid)"
    else
      warn "  failed to create proxy host $domain: $(echo "$resp" | jq -c '.error // .')"; fails=$((fails+1))
    fi
  done
  [ "$fails" -eq 0 ] || warn "  proxy host reconcile had $fails failure(s) — see above"
}

# ─── Run ─────────────────────────────────────────────────────────────────────
configure_qbit
configure_arr "Sonarr" "$SONARR" "$SONARR_KEY" "tv-sonarr" "/data/media/tv"     "$SCRIPT_DIR/services/sonarr/settings"
configure_arr "Radarr" "$RADARR" "$RADARR_KEY" "radarr"    "/data/media/movies"  "$SCRIPT_DIR/services/radarr/settings"
configure_prowlarr
configure_adguard
configure_proxy_hosts

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Service reconcile complete."
echo "  Re-run any time — it converges, never clobbers manual edits."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
