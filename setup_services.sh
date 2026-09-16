#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

log()  { echo -e "\033[1;32m==>\033[0m $1" >&2; }
warn() { echo -e "\033[1;33mWARNING:\033[0m $1" >&2; }
err()  { echo -e "\033[1;31mERROR:\033[0m $1" >&2; exit 1; }

SONARR=http://localhost:8989
RADARR=http://localhost:7878
PROWLARR=http://localhost:9696
QBIT=http://localhost:8181
SEERR=http://localhost:5055
NPM=http://localhost:81
QBIT_HOST=qbittorrent; QBIT_PORT=8080

for bin in curl jq python3; do command -v "$bin" &>/dev/null || err "$bin not found."; done
[ -f "$ENV_FILE" ] || err ".env not found — run setup_script.sh first."

read_env_value() { grep -E "^$1=" "$ENV_FILE" | cut -d= -f2-; }
SONARR_KEY=$(read_env_value SONARR_API_KEY)
RADARR_KEY=$(read_env_value RADARR_API_KEY)
QBIT_PW=$(read_env_value QBIT_PASSWORD)

PROWLARR_KEY=$(grep -oE '<ApiKey>[^<]+' "$SCRIPT_DIR/services/prowlarr/config/config.xml" 2>/dev/null | sed 's/<ApiKey>//' || true)

endpoint_is_up() { curl -fsS -m5 ${2:+-H "$2"} "$1" >/dev/null 2>&1; }

configure_qbit() {
  log "qBittorrent: seeding share limits"
  [ -n "$QBIT_PW" ] || { warn "QBIT_PASSWORD blank — skipping qBit"; return; }
  local cj; cj=$(mktemp); trap 'rm -f "$cj"' RETURN
  if ! curl -fsS -m10 -c "$cj" -o /dev/null \
        --data-urlencode "username=admin" --data-urlencode "password=$QBIT_PW" \
        -H "Referer: $QBIT" "$QBIT/api/v2/auth/login" 2>/dev/null; then
    warn "qBittorrent unreachable/login failed on :8181 — skipping"; return
  fi
  local desired='{"save_path":"/data/downloads/complete","temp_path_enabled":true,"temp_path":"/data/downloads/incomplete","max_ratio_enabled":true,"max_ratio":1,"max_seeding_time_enabled":true,"max_seeding_time":20160,"max_ratio_act":2}'
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

arr_get() { curl -fsS -m10 -H "X-Api-Key: $2" "$1$3"; }
arr_post(){ curl -fsS -m15 -X POST -H "X-Api-Key: $2" -H 'Content-Type: application/json' --data-binary "$4" "$1$3"; }

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

ensure_release_profile() {
  local base="$1" key="$2" file="$3"
  [ -f "$file" ] || { warn "  $(basename "$file") missing — skipping"; return; }
  local name; name=$(jq -r '.name' "$file")
  local id; id=$(arr_get "$base" "$key" "/api/v3/releaseprofile" \
    | jq -r --arg n "$name" '[.[]|select(.name==$n)][0].id // empty')
  if [ -n "$id" ]; then
    local t; t=$(mktemp)
    jq --argjson i "$id" '.id=$i' "$file" > "$t"
    apply_settings_json "$base" "$key" "/api/v3/releaseprofile/$id" "$t" "release profile '$name'"
    rm -f "$t"
  else
    arr_post "$base" "$key" "/api/v3/releaseprofile" "$(cat "$file")" >/dev/null 2>&1 \
      && log "  release profile '$name' created" || warn "  failed creating release profile '$name'"
  fi
}

apply_settings_json() {
  local base="$1" key="$2" endpoint="$3" file="$4"
  local label="${5:-$(basename "$4")}"
  [ -f "$file" ] || { warn "  $file missing — skipping"; return; }
  local current
  current=$(mktemp)
  if arr_get "$base" "$key" "$endpoint" > "$current" 2>/dev/null \
      && jq -e --slurpfile desired "$file" '
        . as $actual | $desired[0] | to_entries | all(.[]; $actual[.key] == .value)
      ' "$current" >/dev/null; then
    rm -f "$current"
    log "  $label already matches"
    return
  fi
  rm -f "$current"
  local resp code body
  resp=$(curl -sS -m15 -X PUT -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
           --data-binary "@$file" -w $'\n%{http_code}' "$base$endpoint" 2>&1)
  code=${resp##*$'\n'}; body=${resp%$'\n'*}
  case "$code" in
    2*) log "  applied $label" ;;
    *)  warn "  failed applying $label (HTTP $code): $(printf '%s' "$body" | jq -r '
          if type=="array" then [.[]|"\(.propertyName // "?"): \(.errorMessage // .)"]|join("; ")
          else (.message // .) end' 2>/dev/null | head -c 300)" ;;
  esac
}

configure_arr() {
  local name="$1" base="$2" key="$3" category="$4" rootpath="$5" sdir="$6"
  log "$name: download client, root folder, tracked settings"
  [ -n "$key" ] || { warn "  $name API key blank — skipping"; return; }
  endpoint_is_up "$base/api/v3/system/status" "X-Api-Key: $key" || { warn "  $name unreachable — skipping"; return; }
  ensure_download_client "$base" "$key" "$category"
  ensure_root_folder     "$base" "$key" "$rootpath"
  apply_settings_json "$base" "$key" "/api/v3/config/naming"          "$sdir/naming.json"
  apply_settings_json "$base" "$key" "/api/v3/config/mediamanagement" "$sdir/mediamanagement.json"
  if [ -f "$sdir/quality-profile-any.json" ]; then
    local qpid; qpid=$(jq -r '.id' "$sdir/quality-profile-any.json")
    local live merged; live=$(mktemp); merged=$(mktemp)
    if arr_get "$base" "$key" "/api/v3/qualityprofile/$qpid" > "$live" 2>/dev/null; then
      jq --slurpfile l "$live" '
        ([.formatItems[]? | {key: .name, value: .score}] | from_entries) as $want
        | .formatItems = [ $l[0].formatItems[] | .score = ($want[.name] // 0) ]
      ' "$sdir/quality-profile-any.json" > "$merged"
      apply_settings_json "$base" "$key" "/api/v3/qualityprofile/$qpid" "$merged" \
        "quality-profile-any.json"
    else
      warn "  could not read live quality profile $qpid — skipping"
    fi
    rm -f "$live" "$merged"
  fi
  [ -f "$sdir/releaseprofile-nodisc.json" ] \
    && ensure_release_profile "$base" "$key" "$sdir/releaseprofile-nodisc.json"
  if [ -f "$sdir/delayprofile.json" ]; then
    local dp; dp=$(mktemp)
    jq '.[0]' "$sdir/delayprofile.json" > "$dp"
    local dpid; dpid=$(jq -r '.id' "$dp")
    apply_settings_json "$base" "$key" "/api/v3/delayprofile/$dpid" "$dp" "delayprofile.json"
    rm -f "$dp"
  fi
}

SEERR_SETTINGS="$SCRIPT_DIR/services/jellyseerr/config/settings.json"
SEERR_PROFILE_RADARR="2160p Remux"
SEERR_PROFILE_SONARR="2160p Quality"

read_seerr_api_key() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["main"]["apiKey"])' "$SEERR_SETTINGS" 2>/dev/null; }

arr_profile_id() { arr_get "$1" "$2" "/api/v3/qualityprofile" | jq -r --arg n "$3" '[.[]|select(.name==$n)][0].id // empty'; }

configure_seerr() {
  log "Seerr: Sonarr/Radarr server link (profile + root folder)"
  [ -f "$SEERR_SETTINGS" ] || { warn "  settings.json missing — Seerr not initialized yet, skipping"; return; }
  local key; key=$(read_seerr_api_key)
  [ -n "$key" ] || { warn "  Seerr API key unreadable in settings.json — skipping"; return; }
  endpoint_is_up "$SEERR/api/v1/status" || { warn "  Seerr unreachable on :5055 — skipping"; return; }
  local spec kind base arrkey root profile pid
  for spec in "sonarr|$SONARR|$SONARR_KEY|/data/media/tv|$SEERR_PROFILE_SONARR" \
              "radarr|$RADARR|$RADARR_KEY|/data/media/movies|$SEERR_PROFILE_RADARR"; do
    IFS='|' read -r kind base arrkey root profile <<<"$spec"
    [ -n "$arrkey" ] || { warn "  $kind: arr API key blank — skipping"; continue; }
    pid=$(arr_profile_id "$base" "$arrkey" "$profile")
    [ -n "$pid" ] || { warn "  $kind: profile '$profile' not in $kind — sync it in Profilarr, then re-run"; continue; }
    python3 - "$SEERR" "$key" "$kind" "$pid" "$profile" "$root" <<'PY'
import sys, json, urllib.request, urllib.error
base, key, kind, pid, pname, root = sys.argv[1:7]
pid = int(pid); is_anime = (kind == "sonarr")
def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"{base}/api/v1/settings/{path}", data=data, method=method,
                               headers={"X-Api-Key": key, "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r))
try:
    servers = req("GET", kind)
except urllib.error.HTTPError as e:
    print(f"  {kind}: GET failed ({e.code}) — skipping"); sys.exit(0)
if not servers:
    print(f"  {kind}: no server configured in Seerr — add it in the UI first"); sys.exit(0)
desired = {"activeProfileId": pid, "activeProfileName": pname, "activeDirectory": root}
if is_anime:
    desired |= {"activeAnimeProfileId": pid, "activeAnimeProfileName": pname, "activeAnimeDirectory": root}
changed = []
for s in servers:
    if not any(k in s and s[k] != v for k, v in desired.items()):
        continue
    sid = s.pop("id")
    for k, v in desired.items():
        if k in s: s[k] = v
    req("PUT", f"{kind}/{sid}", s); changed.append(s["name"])
print(f"  {kind}: " + (f"reconciled {', '.join(changed)} → profile '{pname}' (id {pid}), root {root}"
                       if changed else "already matches"))
PY
  done
}

SMS_HOOK_URL="http://sms-bridge:8080/seerr/hook"
SMS_HOOK_TYPES=120

configure_sms_bridge() {
  log "Seerr: webhook notification agent → sms-bridge"
  [ -f "$SEERR_SETTINGS" ] || { warn "  settings.json missing — Seerr not initialized yet, skipping"; return; }
  local key secret
  key=$(read_seerr_api_key)
  [ -n "$key" ] || { warn "  Seerr API key unreadable in settings.json — skipping"; return; }
  secret=$(read_env_value SMS_BRIDGE_HOOK_SECRET)
  [ -n "$secret" ] || { warn "  SMS_BRIDGE_HOOK_SECRET blank in .env — run setup_script.sh first, skipping"; return; }
  endpoint_is_up "$SEERR/api/v1/status" || { warn "  Seerr unreachable on :5055 — skipping"; return; }

  python3 - "$SEERR" "$key" "$SMS_HOOK_URL" "$SMS_HOOK_TYPES" "$secret" <<'PY'
import sys, json, urllib.request, urllib.error
base, key, hook_url, types, secret = sys.argv[1:6]
types = int(types)

template = json.dumps({
    "notification_type": "{{notification_type}}",
    "subject": "{{subject}}",
    "media_type": "{{media_type}}",
    "tmdbId": "{{media_tmdbid}}",
    "{{request}}": {
        "request_id": "{{request_id}}",
        "requestedBy_username": "{{requestedBy_username}}",
    },
}, indent=2)

def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"{base}/api/v1/settings/notifications/{path}", data=data,
                               method=method,
                               headers={"X-Api-Key": key, "Content-Type": "application/json"})
    raw = urllib.request.urlopen(r).read()
    return json.loads(raw) if raw else {}

try:
    cur = req("GET", "webhook")
except urllib.error.HTTPError as e:
    print(f"  GET webhook settings failed ({e.code}) — skipping"); sys.exit(0)

opts = cur.get("options") or {}
desired_auth = f"Bearer {secret}"
if (cur.get("enabled") is True and cur.get("types") == types
        and opts.get("webhookUrl") == hook_url and opts.get("authHeader") == desired_auth
        and opts.get("jsonPayload") == template):
    print("  webhook agent already matches"); sys.exit(0)

body = {
    "enabled": True,
    "types": types,
    "embedPoster": cur.get("embedPoster", False),
    "options": {
        "webhookUrl": hook_url,
        "jsonPayload": template,
        "authHeader": desired_auth,
        "customHeaders": opts.get("customHeaders") or [],
        "supportVariables": False,
    },
}
try:
    req("POST", "webhook", body)
except urllib.error.HTTPError as e:
    print(f"  POST webhook settings failed ({e.code}): {e.read()[:200].decode('replace')}"); sys.exit(0)
print(f"  webhook agent → {hook_url} (types {types}), auth header set")
PY
}

ensure_prowlarr_app() {
  local appname="$1" syncbase="$2" appkey="$3"
  if arr_get "$PROWLARR" "$PROWLARR_KEY" "/api/v1/applications" | jq -e --arg n "$appname" 'any(.[]; .name==$n)' >/dev/null; then
    log "  application $appname exists"; return
  fi
  [ -n "$appkey" ] || { warn "  $appname API key blank — skipping app link"; return; }
  local impl; impl=$appname
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
  endpoint_is_up "$PROWLARR/api/v1/system/status" "X-Api-Key: $PROWLARR_KEY" || { warn "  Prowlarr unreachable — skipping"; return; }
  ensure_flaresolverr
  ensure_prowlarr_app "Radarr" "http://radarr:7878" "$RADARR_KEY"
  ensure_prowlarr_app "Sonarr" "http://sonarr:8989" "$SONARR_KEY"
}


AG_YAML="$SCRIPT_DIR/services/adguard/conf/AdGuardHome.yaml"

initialize_adguard() {
  curl -fsS -m5 http://localhost:3001/control/status >/dev/null 2>&1 && return
  curl -fsS -m5 http://localhost:3000/control/install/get_addresses >/dev/null 2>&1 || return 0
  command -v op >/dev/null && op whoami >/dev/null 2>&1 \
    || { warn "  sign in to 1Password to initialize AdGuard"; return; }
  local username password body
  username=$(op item get "Marlboro NAS - AdGuard" --vault Private --fields username --reveal 2>/dev/null || true)
  password=$(op item get "Marlboro NAS - AdGuard" --vault Private --fields password --reveal 2>/dev/null || true)
  [ -n "$username" ] && [ -n "$password" ] || { warn "  AdGuard credentials are unavailable"; return; }
  body=$(jq -n --arg username "$username" --arg password "$password" \
    '{web:{ip:"0.0.0.0",port:3001},dns:{ip:"0.0.0.0",port:53},username:$username,password:$password}')
  curl -fsS -m15 -X POST http://localhost:3000/control/install/configure \
    -H 'Content-Type: application/json' -d "$body" >/dev/null \
    && log "  AdGuard initialized on port 3001" \
    || warn "  AdGuard initialization failed"
}

configure_adguard() {
  log "AdGuard: upstream DNS, rate limit, blocklists"
  docker inspect adguard >/dev/null 2>&1 || { warn "  AdGuard not running — skipping"; return; }
  initialize_adguard
  local attempt
  for attempt in {1..30}; do
    [ -f "$AG_YAML" ] && break
    sleep 1
  done
  [ -f "$AG_YAML" ] || { warn "  AdGuard configuration is not available — skipping"; return; }
  if ! sudo -v; then
    warn "  sudo unavailable — set these manually in the AdGuard UI:"
    echo  "    Upstream DNS: add https://dns.cloudflare.com/dns-query" >&2
    echo  "    Rate limit: 300 (or 0)" >&2
    echo  "    Blocklists: EasyList, EasyPrivacy, Steven Black's Hosts" >&2
    return
  fi
  if ! python3 -c 'import yaml' 2>/dev/null; then
    warn "  PyYAML not installed (pip install pyyaml) — skipping AdGuard reconcile"; return
  fi
  local candidate changed=unchanged
  candidate=$(mktemp)
  sudo python3 - "$AG_YAML" "$candidate" <<'PY'
import sys, yaml
source, destination = sys.argv[1:]
with open(source) as f: cfg = yaml.safe_load(f) or {}
dns = cfg.setdefault('dns', {})
ups = dns.setdefault('upstream_dns', [])
cf = 'https://dns.cloudflare.com/dns-query'
if cf not in ups:
    ups.append(cf)
if dns.get('ratelimit') != 300:
    dns['ratelimit'] = 300
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
        filters.append({'enabled': True, 'url': url, 'name': name, 'id': next_id}); next_id += 1
rewrites = cfg.setdefault('filtering', {}).setdefault('rewrites', [])
want_rewrites = [{'domain': 'marlboro', 'answer': '192.168.0.10', 'enabled': True}]
for rw in want_rewrites:
    if rw not in rewrites:
        rewrites.append(rw)
with open(destination, 'w') as f: yaml.safe_dump(cfg, f, sort_keys=False, default_flow_style=False)
PY
  if ! sudo cmp -s "$candidate" "$AG_YAML"; then
    (cd "$SCRIPT_DIR" && docker compose stop adguard >/dev/null)
    if sudo install -m 0600 "$candidate" "$AG_YAML"; then
      changed=changed
    else
      (cd "$SCRIPT_DIR" && docker compose up -d adguard >/dev/null)
      rm -f "$candidate"
      warn "  failed to update AdGuard settings"
      return
    fi
    (cd "$SCRIPT_DIR" && docker compose up -d adguard >/dev/null)
  fi
  rm -f "$candidate"
  if [ "$changed" = "changed" ]; then
    log "  AdGuard settings reconciled"
  else
    log "  AdGuard settings already match"
  fi
}


PTERO_NODE_NAME=marlboro
PTERO_NODE_FQDN=marlboro.tail314238.ts.net
PTERO_ROOT=/mnt/tank/pterodactyl
PTERO_SUBNET=172.22.0.0/16
PTERO_NETWORK=pterodactyl_nw
PTERO_BRIDGE=pterodactyl0
PTERO_GATEWAY=172.22.0.1
PTERO_ALLOC_IP=0.0.0.0
PTERO_ALLOC_PORTS=(2456 2457)
PTERO_VALHEIM_SERVER=Valheim
PTERO_VALHEIM_CROSSPLAY=1
PTERO_VALHEIM_AUTO_UPDATE=1
LEGACY_PTERO_VALHEIM_SCHEDULE="Nightly update restart"

ptero_sql() {
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T pterodactyl-db \
    mariadb -N -B -u root -p"$(read_env_value PTERO_DB_ROOT_PASSWORD)" panel -e "$1" 2>/dev/null || true
}

ptero_artisan() {
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T pterodactyl-panel php artisan "$@"
}

ensure_pterodactyl_admin() {
  [ -z "$(ptero_sql "SELECT id FROM users WHERE root_admin=1 LIMIT 1;")" ] || { log "  admin user exists"; return; }
  command -v op >/dev/null && op whoami >/dev/null 2>&1 \
    || { warn "  sign in to 1Password to create the panel admin"; return; }
  local username password
  username=$(op item get "Marlboro NAS - Pterodactyl Admin" --vault Private --fields username --reveal 2>/dev/null || true)
  password=$(op item get "Marlboro NAS - Pterodactyl Admin" --vault Private --fields password --reveal 2>/dev/null || true)
  [ -n "$username" ] && [ -n "$password" ] || { warn "  Pterodactyl admin credentials are unavailable"; return; }
  ptero_artisan p:user:make \
    --email=bencalegari@navapbc.com --username="$username" \
    --name-first=Ben --name-last=Calegari --password="$password" --admin=1 >/dev/null \
    && log "  admin user created" \
    || warn "  failed to create the admin user"
}

configure_ptero_client_key() {
  log "Pterodactyl: client API key for Glance"
  if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps --status running --services 2>/dev/null | grep -qx pterodactyl-panel; then
    warn "  pterodactyl-panel not running — skipping"; return
  fi

  local out state key env_key
  out=$(ptero_artisan tinker --execute "$(cat <<'PHP'
$user = \Pterodactyl\Models\User::where('root_admin', true)->orderBy('id')->first();
if (!$user) {
    echo "no-admin\n";
} else {
    $key = \Pterodactyl\Models\ApiKey::where('user_id', $user->id)
        ->where('key_type', \Pterodactyl\Models\ApiKey::TYPE_ACCOUNT)
        ->orderBy('id')->first();
    if ($key) {
        echo "existing " . $key->identifier . decrypt($key->token) . "\n";
    } else {
        $secret = \Illuminate\Support\Str::random(\Pterodactyl\Models\ApiKey::KEY_LENGTH);
        $key = new \Pterodactyl\Models\ApiKey();
        $key->forceFill([
            'user_id' => $user->id,
            'key_type' => \Pterodactyl\Models\ApiKey::TYPE_ACCOUNT,
            'identifier' => \Pterodactyl\Models\ApiKey::generateTokenIdentifier(\Pterodactyl\Models\ApiKey::TYPE_ACCOUNT),
            'token' => encrypt($secret),
            'memo' => 'Glance Valheim tile',
            'allowed_ips' => [],
        ])->save();
        echo "created " . $key->identifier . $secret . "\n";
    }
}
PHP
)" 2>/dev/null | tr -d '\r' | grep -E '^(no-admin|existing|created)' || true)

  read -r state key <<<"${out:-}"
  case "$state" in
    "") warn "  key check returned nothing — check the panel"; return ;;
    no-admin) warn "  no admin user yet — create one first"; return ;;
    created) warn "  created a client API key for Glance" ;;
  esac

  env_key=$(read_env_value PTERO_CLIENT_API_KEY)
  if [ "$env_key" = "$key" ]; then
    log "  client API key matches .env"
    return
  fi
  if command -v op >/dev/null && op whoami >/dev/null 2>&1; then
    if op item get "Marlboro NAS - Pterodactyl Client API" --vault Private >/dev/null 2>&1; then
      op item edit "Marlboro NAS - Pterodactyl Client API" --vault Private \
        "api_token[text]=$key" >/dev/null
    else
      op item create --category Login --title "Marlboro NAS - Pterodactyl Client API" \
        --vault Private --tags marlboro-nas username=pterodactyl \
        "api_token[text]=$key" >/dev/null
    fi
    log "  client API key stored in 1Password"
  else
    warn "  sign in to 1Password to store the client API key"
  fi
}

reconcile_valheim_variables() {
  local pair variable_name desired_value current_value row_id
  for pair in "ENABLE_CROSSPLAY=$PTERO_VALHEIM_CROSSPLAY" \
              "AUTO_UPDATE=$PTERO_VALHEIM_AUTO_UPDATE"; do
    variable_name=${pair%%=*}
    desired_value=${pair#*=}
    row_id=$(ptero_sql "SELECT sv.id FROM server_variables sv
                          JOIN egg_variables ev ON ev.id = sv.variable_id
                          JOIN servers s ON s.id = sv.server_id
                        WHERE ev.env_variable='$variable_name'
                          AND s.name='$PTERO_VALHEIM_SERVER' LIMIT 1;")
    if [ -z "$row_id" ]; then
      log "  no $PTERO_VALHEIM_SERVER server yet — skipping $variable_name"
      continue
    fi
    current_value=$(ptero_sql "SELECT variable_value FROM server_variables WHERE id=$row_id;")
    if [ "$current_value" = "$desired_value" ]; then
      log "  $variable_name already $desired_value"
    else
      ptero_sql "UPDATE server_variables SET variable_value='$desired_value' WHERE id=$row_id;" >/dev/null
      warn "  $variable_name $current_value → $desired_value; restart Valheim to apply it"
    fi
  done
}

remove_legacy_valheim_schedule() {
  local schedule_id
  schedule_id=$(ptero_sql "SELECT s.id FROM schedules s
                             JOIN servers sv ON sv.id = s.server_id
                           WHERE sv.name='$PTERO_VALHEIM_SERVER'
                             AND s.name='$LEGACY_PTERO_VALHEIM_SCHEDULE' LIMIT 1;")
  if [ -z "$schedule_id" ]; then
    log "  no legacy panel restart schedule"
    return
  fi
  ptero_sql "DELETE FROM tasks WHERE schedule_id=$schedule_id;" >/dev/null
  ptero_sql "DELETE FROM schedules WHERE id=$schedule_id;" >/dev/null
  warn "  removed legacy panel schedule '$LEGACY_PTERO_VALHEIM_SCHEDULE'"
}

ensure_pterodactyl_network() {
  if ! docker network inspect "$PTERO_NETWORK" >/dev/null 2>&1; then
    docker network create --driver bridge \
      --subnet "$PTERO_SUBNET" --gateway "$PTERO_GATEWAY" \
      --opt com.docker.network.bridge.name="$PTERO_BRIDGE" \
      --opt com.docker.network.bridge.enable_icc=true \
      --opt com.docker.network.bridge.enable_ip_masquerade=true \
      --opt com.docker.network.bridge.host_binding_ipv4=0.0.0.0 \
      --opt com.docker.network.driver.mtu=1500 \
      "$PTERO_NETWORK" >/dev/null \
      && log "  $PTERO_NETWORK created (IPv4-only, $PTERO_SUBNET)" \
      || warn "  failed to create $PTERO_NETWORK"
  elif [ "$(docker network inspect "$PTERO_NETWORK" --format '{{.EnableIPv6}}')" = "true" ]; then
    warn "  $PTERO_NETWORK has IPv6 enabled; stop game servers and recreate it"
  else
    log "  $PTERO_NETWORK exists (IPv4-only)"
  fi
}

configure_pterodactyl() {
  log "Pterodactyl: location + node + wings config"
  local cfg="$SCRIPT_DIR/services/pterodactyl/wings-etc/config.yml"

  if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps --status running --services 2>/dev/null | grep -qx pterodactyl-panel; then
    warn "  pterodactyl-panel not running — skipping"; return
  fi
  if [ -z "$(ptero_sql 'SHOW TABLES LIKE "nodes";')" ]; then
    warn "  panel migrations haven't finished yet — re-run once it's up"; return
  fi

  ensure_pterodactyl_admin

  local loc_id
  loc_id=$(ptero_sql "SELECT id FROM locations WHERE short='home' LIMIT 1;")
  if [ -n "$loc_id" ]; then
    log "  location home exists (id $loc_id)"
  else
    ptero_artisan p:location:make --short=home --long="Marlboro" >/dev/null \
      && loc_id=$(ptero_sql "SELECT id FROM locations WHERE short='home' LIMIT 1;") \
      && log "  location home created (id $loc_id)" \
      || { warn "  failed to create location"; return; }
  fi

  local node_id
  node_id=$(ptero_sql "SELECT id FROM nodes WHERE name='$PTERO_NODE_NAME' LIMIT 1;")
  if [ -n "$node_id" ]; then
    log "  node $PTERO_NODE_NAME exists (id $node_id)"
  else
    ptero_artisan p:node:make \
      --name="$PTERO_NODE_NAME" --description="Marlboro NAS" --locationId="$loc_id" \
      --fqdn="$PTERO_NODE_FQDN" --public=1 --scheme=http --proxy=0 --maintenance=0 \
      --maxMemory=3072 --overallocateMemory=0 --maxDisk=51200 --overallocateDisk=0 \
      --uploadSize=100 --daemonListeningPort=8092 --daemonSFTPPort=2022 \
      --daemonBase="$PTERO_ROOT/volumes" >/dev/null \
      && node_id=$(ptero_sql "SELECT id FROM nodes WHERE name='$PTERO_NODE_NAME' LIMIT 1;") \
      && log "  node $PTERO_NODE_NAME created (id $node_id)" \
      || { warn "  failed to create node"; return; }
  fi
  [ -n "$node_id" ] || { warn "  no node id — skipping wings config"; return; }

  local want_token have_token
  want_token=$(ptero_sql "SELECT daemon_token_id FROM nodes WHERE id=$node_id;")
  have_token=$(python3 -c "
import sys,yaml
try:
    print(yaml.safe_load(open('$cfg')).get('token_id') or '')
except Exception:
    print('')
" 2>/dev/null)

  if [ -f "$cfg" ] && [ -n "$want_token" ] && [ "$want_token" = "$have_token" ]; then
    log "  wings config.yml already matches node $node_id"
  else
    ptero_artisan p:node:configuration "$node_id" --format=yaml > "$cfg.raw" 2>/dev/null \
      || { warn "  p:node:configuration failed"; rm -f "$cfg.raw"; return; }
    [ -s "$cfg.raw" ] || { warn "  p:node:configuration produced nothing"; rm -f "$cfg.raw"; return; }
    mv "$cfg.raw" "$cfg"
    log "  wings config.yml generated for node $node_id"
  fi

  local config_status
  config_status=$(python3 - "$cfg" "$PTERO_ROOT" "$PTERO_SUBNET" "$PTERO_GATEWAY" <<'PY'
import sys, yaml
cfg, root, subnet, gw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = yaml.safe_load(open(cfg)) or {}
before = yaml.safe_dump(d, default_flow_style=False, sort_keys=False)
sysd = d.setdefault('system', {})
sysd['root_directory']    = root
sysd['log_directory']     = f'{root}/logs'
sysd['data']              = f'{root}/volumes'
sysd['archive_directory'] = f'{root}/archives'
sysd['backup_directory']  = f'{root}/backups'
sysd['tmp_directory']     = '/tmp/pterodactyl'
net = d.setdefault('docker', {}).setdefault('network', {})
net['interface'] = gw
v4 = net.setdefault('interfaces', {}).setdefault('v4', {})
v4['subnet'], v4['gateway'] = subnet, gw
after = yaml.safe_dump(d, default_flow_style=False, sort_keys=False)
if before != after:
    with open(cfg, 'w') as f: f.write(after)
print('changed' if before != after else 'unchanged')
PY
)
  log "  wings config.yml $config_status"

  local port
  for port in "${PTERO_ALLOC_PORTS[@]}"; do
    if [ -n "$(ptero_sql "SELECT id FROM allocations WHERE node_id=$node_id AND ip='$PTERO_ALLOC_IP' AND port=$port LIMIT 1;")" ]; then
      log "  allocation $PTERO_ALLOC_IP:$port exists"
    else
      ptero_sql "INSERT INTO allocations (node_id, ip, port, created_at, updated_at)
                 SELECT $node_id, '$PTERO_ALLOC_IP', $port, NOW(), NOW()
                 FROM DUAL WHERE NOT EXISTS (
                   SELECT 1 FROM allocations WHERE node_id=$node_id AND ip='$PTERO_ALLOC_IP' AND port=$port);" >/dev/null
      if [ -n "$(ptero_sql "SELECT id FROM allocations WHERE node_id=$node_id AND ip='$PTERO_ALLOC_IP' AND port=$port LIMIT 1;")" ]; then
        log "  allocation $PTERO_ALLOC_IP:$port created"
      else
        warn "  failed to create allocation $PTERO_ALLOC_IP:$port"
      fi
    fi
  done

  reconcile_valheim_variables
  remove_legacy_valheim_schedule
  ensure_pterodactyl_network

  log "  restart wings to pick up config changes: docker compose restart wings"
}

NPM_HOSTS=(
  "marlboro-bc.duckdns.org|192.168.0.10|8096|true|true"
  "jellyfin.marlboro-bc.duckdns.org|192.168.0.10|8096|true|false"
  "plex.marlboro-bc.duckdns.org|192.168.0.10|32400|true|true"
  "seerr.marlboro-bc.duckdns.org|seerr|5055|true|false"
  "git.marlboro-bc.duckdns.org|forgejo|3000|true|false"
  "coolify.marlboro-bc.duckdns.org|192.168.0.10|8000|true|true"
  "sms.marlboro-bc.duckdns.org|sms-bridge|8080|false|true|sms-inbound-only"
)

npm_advanced_config() {
  case "$1" in
    sms-inbound-only) cat <<'NGINX'
location = /twilio/inbound {
    resolver 127.0.0.11 valid=10s ipv6=off;
    set $sms_upstream sms-bridge;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Scheme $scheme;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_pass http://$sms_upstream:8080;
}
location / {
    return 404;
}
NGINX
      ;;
    *) : ;;
  esac
}

npm_cert_id_for() { echo "$NPM_CERTS" | jq -r --arg d "$1" '[.[]|select(.domain_names|index($d))][0].id // empty'; }
npm_host_exists() { echo "$NPM_PHOSTS" | jq -e --arg d "$1" 'any(.[]; .domain_names|index($d))' >/dev/null; }

npm_login_token() {
  curl -sS -m10 -X POST "$NPM/api/tokens" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg email "$1" --arg password "$2" '{identity:$email,secret:$password}')" \
    | jq -r '.token // empty'
}

configure_npm_admin_credentials() {
  local email="$1" password="$2" token user_id user_body
  token=$(npm_login_token "$email" "$password")
  if [ -n "$token" ]; then
    printf '%s' "$token"
    return
  fi
  token=$(npm_login_token admin@example.com changeme)
  [ -n "$token" ] || return 0
  user_id=$(curl -fsS -m10 -H "Authorization: Bearer $token" "$NPM/api/users" \
    | jq -r '[.[] | select(.roles | index("admin"))][0].id // empty')
  [ -n "$user_id" ] || return 0
  user_body=$(jq -n --arg email "$email" \
    '{name:"Administrator",nickname:"Admin",email:$email,roles:["admin"],is_disabled:false}')
  curl -fsS -m10 -X PUT -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -d "$user_body" "$NPM/api/users/$user_id" >/dev/null || return 0
  curl -fsS -m10 -X PUT -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg password "$password" '{type:"password",current:"changeme",secret:$password}')" \
    "$NPM/api/users/$user_id/auth" >/dev/null || return 0
  npm_login_token "$email" "$password"
}

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
  NPM_CERTS=$(curl -s -m10 "${NPM_AUTH[@]}" "$NPM/api/nginx/certificates")
  echo "$id"
}

configure_proxy_hosts() {
  log "Nginx Proxy Manager: proxy hosts + certs"
  local email pass; email=$(read_env_value NGINX_EMAIL_ID); pass=$(read_env_value NGINX_PASSWORD); NPM_DUCK=$(read_env_value DUCKDNS_TOKEN)
  [ -n "$email" ] && [ -n "$pass" ] || { warn "  NGINX_EMAIL_ID/NGINX_PASSWORD missing in .env — skipping"; return; }
  curl -fsS -m5 "$NPM/api/" >/dev/null 2>&1 || { warn "  NPM unreachable at :81 — skipping"; return; }
  local token
  token=$(configure_npm_admin_credentials "$email" "$pass")
  [ -n "$token" ] || { warn "  NPM token failed — check NGINX_EMAIL_ID/NGINX_PASSWORD — skipping"; return; }
  NPM_AUTH=(-H "Authorization: Bearer $token")
  NPM_CERTS=$(curl -s -m10 "${NPM_AUTH[@]}" "$NPM/api/nginx/certificates")
  NPM_PHOSTS=$(curl -s -m10 "${NPM_AUTH[@]}" "$NPM/api/nginx/proxy-hosts")

  local fails=0 row domain fhost fport ws sslf snip adv cid body resp
  for row in "${NPM_HOSTS[@]}"; do
    IFS='|' read -r domain fhost fport ws sslf snip <<<"$row"
    if npm_host_exists "$domain"; then log "  proxy host $domain exists"; continue; fi
    adv=""; [ -n "${snip:-}" ] && adv=$(npm_advanced_config "$snip")
    cid=$(npm_ensure_cert "$domain")
    [ -n "$cid" ] || { warn "  skipping $domain — no certificate"; fails=$((fails+1)); continue; }
    body=$(jq -n --arg d "$domain" --arg fh "$fhost" --argjson fp "$fport" \
      --argjson ws "$ws" --argjson sslf "$sslf" --argjson cid "$cid" --arg adv "$adv" \
      '{domain_names:[$d],forward_scheme:"http",forward_host:$fh,forward_port:$fp,
        certificate_id:$cid,ssl_forced:$sslf,http2_support:true,
        allow_websocket_upgrade:$ws,block_exploits:true,caching_enabled:false,
        hsts_enabled:false,hsts_subdomains:false,access_list_id:0,
        advanced_config:$adv,locations:[],meta:{}}')
    resp=$(curl -s -m15 -X POST "$NPM/api/nginx/proxy-hosts" "${NPM_AUTH[@]}" -H 'Content-Type: application/json' -d "$body")
    if echo "$resp" | jq -e '.id' >/dev/null 2>&1; then
      log "  created proxy host $domain → $fhost:$fport (cert $cid)"
    else
      warn "  failed to create proxy host $domain: $(echo "$resp" | jq -c '.error // .')"; fails=$((fails+1))
    fi
  done
  [ "$fails" -eq 0 ] || warn "  proxy host reconcile had $fails failure(s) — see above"
}

configure_forgejo_admin() {
  log "Forgejo: admin user"
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps --status running --services 2>/dev/null \
    | grep -qx forgejo || { warn "  Forgejo not running — skipping"; return; }
  command -v op >/dev/null && op whoami >/dev/null 2>&1 \
    || { warn "  sign in to 1Password to create the Forgejo admin"; return; }
  local username password
  username=$(op item get "Marlboro NAS - Forgejo" --vault Private --fields username --reveal 2>/dev/null || true)
  password=$(op item get "Marlboro NAS - Forgejo" --vault Private --fields password --reveal 2>/dev/null || true)
  [ -n "$username" ] && [ -n "$password" ] || { warn "  Forgejo credentials are unavailable"; return; }
  if docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T --user 1000:1000 forgejo forgejo admin user list 2>/dev/null \
      | awk -v username="$username" '$2 == username { found=1 } END { exit !found }'; then
    log "  admin user exists"
    return
  fi
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T --user 1000:1000 forgejo forgejo admin user create \
    --username "$username" --password "$password" --email bencalegari@navapbc.com \
    --admin --must-change-password=false >/dev/null \
    && log "  admin user created" \
    || warn "  failed to create the admin user"
}

configure_scrutiny() {
  log "Scrutiny: metric status threshold"
  local url=http://localhost:8085/api/settings current
  current=$(curl -fsS -m5 "$url" 2>/dev/null) || { warn "  Scrutiny unreachable — skipping"; return; }
  if printf '%s' "$current" | jq -e '.settings.metrics.status_threshold == 1' >/dev/null 2>&1; then
    log "  status threshold already Smart"
    return
  fi
  printf '%s' "$current" | jq '.settings | .metrics.status_threshold = 1' \
    | curl -fsS -m10 -X POST "$url" -H 'Content-Type: application/json' --data-binary @- >/dev/null \
    && log "  status threshold set to Smart" \
    || warn "  failed to set status threshold"
}

configure_portainer_admin() {
  log "Portainer: admin user"
  local username password setup_token="" status attempt
  status=$(curl -sS -m5 -o /dev/null -w '%{http_code}' http://localhost:9000/api/users/admin/check || true)
  [ "$status" = "404" ] || { [ "$status" = "204" ] && log "  admin user exists" || warn "  Portainer unreachable — skipping"; return; }
  command -v op >/dev/null && op whoami >/dev/null 2>&1 \
    || { warn "  sign in to 1Password to create the Portainer admin"; return; }
  username=$(op item get "Marlboro NAS - Portainer" --vault Private --fields username --reveal 2>/dev/null || true)
  password=$(op item get "Marlboro NAS - Portainer" --vault Private --fields password --reveal 2>/dev/null || true)
  [ -n "$username" ] && [ -n "$password" ] || { warn "  Portainer credentials are unavailable"; return; }
  docker restart portainer >/dev/null
  for attempt in {1..30}; do
    setup_token=$(docker logs --since 1m portainer 2>&1 \
      | sed -n 's/.*setup_token=\([^[:space:]]*\).*/\1/p' | tail -n 1 || true)
    status=$(curl -sS -m2 -o /dev/null -w '%{http_code}' http://localhost:9000/api/users/admin/check || true)
    [ -n "$setup_token" ] && [ "$status" = "404" ] && break
    sleep 1
  done
  [ -n "${setup_token:-}" ] || { warn "  Portainer setup token is unavailable"; return; }
  [ "$status" = "404" ] || { warn "  Portainer API did not become ready"; return; }
  curl -fsS -m10 -X POST http://localhost:9000/api/users/admin/init \
    -H 'Content-Type: application/json' -H "X-Setup-Token: $setup_token" \
    -d "$(jq -n --arg username "$username" --arg password "$password" '{username:$username,password:$password}')" >/dev/null \
    && log "  admin user created" \
    || warn "  failed to create the admin user"
}

jellyfin_authenticate() {
  curl -fsS -m10 -X POST http://localhost:8096/Users/AuthenticateByName \
    -H 'Content-Type: application/json' \
    -H 'Authorization: MediaBrowser Client="Marlboro Setup", Device="Marlboro", DeviceId="marlboro-setup", Version="1.0.0"' \
    -d "$(jq -n --arg username "$1" --arg password "$2" '{Username:$username,Pw:$password}')" \
    | jq -r '.AccessToken // empty'
}

ensure_jellyfin_library() {
  local token="$1" name="$2" type="$3" path="$4" libraries
  libraries=$(curl -fsS -m10 -H "X-Emby-Token: $token" http://localhost:8096/Library/VirtualFolders) || return
  if ! printf '%s' "$libraries" | jq -e --arg name "$name" 'any(.[]; .Name == $name)' >/dev/null; then
    curl -fsS -m15 -X POST -H "X-Emby-Token: $token" -H 'Content-Type: application/json' \
      --data '{"LibraryOptions":{}}' \
      "http://localhost:8096/Library/VirtualFolders?name=$name&collectionType=$type&refreshLibrary=false" >/dev/null || return
    libraries='[]'
  fi
  if printf '%s' "$libraries" | jq -e --arg name "$name" --arg path "$path" \
      'any(.[]; .Name == $name and any(.Locations[]?; . == $path))' >/dev/null; then
    log "  $name library exists"
    return
  fi
  curl -fsS -m15 -X POST -H "X-Emby-Token: $token" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg path "$path" '{Path:$path}')" \
    "http://localhost:8096/Library/VirtualFolders/Paths?name=$name&refreshLibrary=false" >/dev/null \
    && log "  $name library created" \
    || warn "  failed to create the $name library"
}

configure_jellyfin() {
  log "Jellyfin: administrator and libraries"
  local public_info username password token
  public_info=$(curl -fsS -m5 http://localhost:8096/System/Info/Public 2>/dev/null) \
    || { warn "  Jellyfin unreachable — skipping"; return; }
  command -v op >/dev/null && op whoami >/dev/null 2>&1 \
    || { warn "  sign in to 1Password to configure Jellyfin"; return; }
  username=$(op item get "Marlboro NAS - Jellyfin" --vault Private --fields username --reveal 2>/dev/null || true)
  password=$(op item get "Marlboro NAS - Jellyfin" --vault Private --fields password --reveal 2>/dev/null || true)
  [ -n "$username" ] && [ -n "$password" ] || { warn "  Jellyfin credentials are unavailable"; return; }
  if [ "$(printf '%s' "$public_info" | jq -r '.StartupWizardCompleted')" != "true" ]; then
    curl -fsS -m10 -X POST http://localhost:8096/Startup/Configuration \
      -H 'Content-Type: application/json' \
      -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null \
      && curl -fsS -m10 http://localhost:8096/Startup/User >/dev/null \
      && curl -fsS -m10 -X POST http://localhost:8096/Startup/User \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg name "$username" --arg password "$password" '{Name:$name,Password:$password}')" >/dev/null \
      && curl -fsS -m10 -X POST http://localhost:8096/Startup/RemoteAccess \
        -H 'Content-Type: application/json' \
        -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null \
      && curl -fsS -m10 -X POST http://localhost:8096/Startup/Complete >/dev/null \
      && log "  administrator created" \
      || { warn "  startup configuration failed"; return; }
  fi
  token=$(jellyfin_authenticate "$username" "$password" 2>/dev/null || true)
  [ -n "$token" ] || { warn "  stored credentials do not match the Jellyfin administrator — skipping libraries"; return; }
  ensure_jellyfin_library "$token" Movies movies /media/movies
  ensure_jellyfin_library "$token" TV tvshows /media/tv
}

configure_qbit
configure_arr "Sonarr" "$SONARR" "$SONARR_KEY" "tv-sonarr" "/data/media/tv"     "$SCRIPT_DIR/services/sonarr/settings"
configure_arr "Radarr" "$RADARR" "$RADARR_KEY" "radarr"    "/data/media/movies"  "$SCRIPT_DIR/services/radarr/settings"
configure_seerr
configure_sms_bridge
configure_prowlarr
configure_adguard
configure_pterodactyl
configure_ptero_client_key
configure_proxy_hosts
configure_forgejo_admin
configure_scrutiny
configure_portainer_admin
configure_jellyfin

log "Service reconcile complete"
