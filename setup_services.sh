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
#   Seerr        — Sonarr/Radarr server link (quality profile + root folder),
#                  resolved by profile NAME so it survives Profilarr id churn;
#                  plus the webhook notification agent that drives sms-bridge
#   Prowlarr     — Sonarr/Radarr applications + FlareSolverr indexer proxy
#   AdGuard      — upstream DNS, rate limit, DNS blocklists (sudo yaml reconcile)
#   NginxProxyMgr— proxy hosts + Let's Encrypt certs (DNS-01 via DuckDNS) from
#                  the declarative HOSTS list below
#   Pterodactyl  — location + node, then generates Wings' config.yml and patches
#                  in the paths/subnet the panel doesn't emit (see Part 24);
#                  plus the Valheim egg variables that let the game self-update
#                  on restart (Part 24.16)
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
SEERR=http://localhost:5055
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

# Sonarr-only: block full-disc releases by title. Sonarr has no BR-DISK quality
# (Radarr does), so a COMPLETE.BLURAY release misparses as plain Bluray-1080p and
# slips straight past the quality filter. A release profile is the only lever.
# Matched by name so re-runs converge instead of stacking duplicates.
ensure_release_profile() {
  local base="$1" key="$2" file="$3"
  [ -f "$file" ] || { warn "  $(basename "$file") missing — skipping"; return; }
  local name; name=$(jq -r '.name' "$file")
  local id; id=$(arr_get "$base" "$key" "/api/v3/releaseprofile" \
    | jq -r --arg n "$name" '[.[]|select(.name==$n)][0].id // empty')
  if [ -n "$id" ]; then
    local t; t=$(mktemp)
    jq --argjson i "$id" '.id=$i' "$file" > "$t"
    arr_put "$base" "$key" "/api/v3/releaseprofile/$id" "@$t" >/dev/null 2>&1 \
      && log "  release profile '$name' updated" || warn "  failed updating release profile '$name'"
    rm -f "$t"
  else
    arr_post "$base" "$key" "/api/v3/releaseprofile" "$(cat "$file")" >/dev/null 2>&1 \
      && log "  release profile '$name' created" || warn "  failed creating release profile '$name'"
  fi
}

# Apply a tracked settings JSON (singleton config endpoints) if present.
# arg5 optional: label to report instead of the (possibly temp) filename.
# Surfaces the *arr's validation body on failure — swallowing it hid a stale
# quality-profile formatItems list that had silently stopped applying.
apply_settings_json() {
  local base="$1" key="$2" endpoint="$3" file="$4" label="${5:-$(basename "$4")}"
  [ -f "$file" ] || { warn "  $file missing — skipping"; return; }
  # Deliberately not curl -fsS / arr_put: -f discards the response body, which is
  # where the *arr puts its validation errors.
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
  up "$base/api/v3/system/status" "X-Api-Key: $key" || { warn "  $name unreachable — skipping"; return; }
  ensure_download_client "$base" "$key" "$category"
  ensure_root_folder     "$base" "$key" "$rootpath"
  # Singleton configs: PUT the exported object straight back (converges).
  apply_settings_json "$base" "$key" "/api/v3/config/naming"          "$sdir/naming.json"
  apply_settings_json "$base" "$key" "/api/v3/config/mediamanagement" "$sdir/mediamanagement.json"
  # Quality profile "Any" (id in the file) + delay profile (list → id 1).
  # Note: BR-DISK (Radarr) and Raw-HD are OFF in the tracked "Any" profiles —
  # full BluRay discs are unplayable through Jellyfin's libbluray path. See the
  # BluRay ISO caveat in README Part 16.5.
  #
  # The formatItems list must contain EVERY custom format currently in the *arr
  # and no extras, or the PUT 400s with "All Custom Formats and no extra ones
  # need to be present inside your Profile!". Profilarr adds/renames Dictionarry
  # formats over time, so a stored list goes stale and silently stops applying.
  # Re-key the tracked scores onto the live format list before PUTting: the file
  # stays the source of truth for intent, the live server decides the roster.
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
  # Sonarr only (Radarr has no release profiles — it uses Custom Formats, and
  # Dictionarry already scores "Full Disc" at -999999 in the 2160p profile).
  [ -f "$sdir/releaseprofile-nodisc.json" ] \
    && ensure_release_profile "$base" "$key" "$sdir/releaseprofile-nodisc.json"
  if [ -f "$sdir/delayprofile.json" ]; then
    local dp; dp=$(mktemp)
    jq '.[0]' "$sdir/delayprofile.json" > "$dp"
    local dpid; dpid=$(jq -r '.id' "$dp")
    arr_put "$base" "$key" "/api/v3/delayprofile/$dpid" "@$dp" >/dev/null 2>&1 \
      && log "  applied delayprofile.json" || warn "  failed applying delay profile"
    rm -f "$dp"
  fi
}

# ─── Seerr: Sonarr/Radarr server link (quality profile + root folder) ────────
# Jellyseerr keeps its *arr server config (which quality profile + root folder a
# request uses) in its OWN settings.json — gitignored because the app mutates it.
# It drifted once: pointed at dead profileId 7 + root '/tv' (Sonarr's real root
# is /data/media/tv), so every request 400'd with "Quality Profile does not
# exist" / "Root folder '/tv' does not exist". Reconcile the link here.
#
# Resolve the profile by NAME (not id): Profilarr sync churns profile ids, so a
# hardcoded id is exactly what broke. These are live Profilarr-managed profiles —
# change them here if you want requests to use different ones.
#
# Movies and TV deliberately differ. Both Dictionarry profiles ban full discs
# ("Full Disc" / "Full Disc (Quality Match)" at -999999, and neither lists
# BR-DISK or Raw-HD as a quality at all), so neither can pull an unplayable ISO —
# see the BluRay ISO caveat in README Part 16.5. The difference is the ceiling:
#   2160p Remux   — allows Remux-2160p/1080p, i.e. lossless. ~40-60GB per movie.
#   2160p Quality — caps at Bluray-2160p re-encodes and bans the Remux format
#                   (-999999). ~15-30GB per TV episode at remux, which is not
#                   worth it: 4K HDR remuxes at 60-80 Mbps always force an
#                   HDR->SDR tonemap on the webOS path, and the UHD 630 is
#                   already at its limit doing that (see Part 16.5).
SEERR_SETTINGS="$SCRIPT_DIR/services/jellyseerr/config/settings.json"
SEERR_PROFILE_RADARR="2160p Remux"
SEERR_PROFILE_SONARR="2160p Quality"

# Read Seerr's API key from its own settings.json (no separate 1Password item).
seerr_key() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["main"]["apiKey"])' "$SEERR_SETTINGS" 2>/dev/null; }

# Resolve a quality-profile id by name in an *arr. Echoes id, or empty if absent.
arr_profile_id() { arr_get "$1" "$2" "/api/v3/qualityprofile" | jq -r --arg n "$3" '[.[]|select(.name==$n)][0].id // empty'; }

configure_seerr() {
  log "Seerr: Sonarr/Radarr server link (profile + root folder)"
  [ -f "$SEERR_SETTINGS" ] || { warn "  settings.json missing — Seerr not initialized yet, skipping"; return; }
  local key; key=$(seerr_key)
  [ -n "$key" ] || { warn "  Seerr API key unreadable in settings.json — skipping"; return; }
  up "$SEERR/api/v1/status" || { warn "  Seerr unreachable on :5055 — skipping"; return; }
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
pid = int(pid); is_anime = (kind == "sonarr")   # Radarr has no anime fields
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
    sid = s.pop("id")                       # id is read-only in the PUT body
    for k, v in desired.items():
        if k in s: s[k] = v
    req("PUT", f"{kind}/{sid}", s); changed.append(s["name"])
print(f"  {kind}: " + (f"reconciled {', '.join(changed)} → profile '{pname}' (id {pid}), root {root}"
                       if changed else "already matches"))
PY
  done
}

# ─── Seerr: webhook notification agent -> sms-bridge ─────────────────────────
# Fires the "it's ready" half of the SMS bridge. Seerr POSTs to sms-bridge, which
# looks the request id up in its SQLite map and texts whoever asked for it.
#
# Types is a bitmask of Notification (server/lib/notifications/index.ts):
#   MEDIA_AVAILABLE 8 | MEDIA_FAILED 16 | TEST_NOTIFICATION 32 | MEDIA_DECLINED 64
# = 120. FAILED/DECLINED are included on purpose — a request that dies in silence is
# worse than no bot at all. TEST is included so the UI's Test button reaches the bridge.
#
# jsonPayload goes over the wire as a PLAIN JSON string; Seerr JSON.stringify's and
# base64's it server-side, and GET hands it back decoded (routes/settings/
# notifications.ts:276-325). So we send and diff the raw template, not base64.
#
# The "{{request}}" key is Seerr's own convention: it becomes "request", or null when
# the event carries no request. Don't "fix" it into a plain "request" key.
SMS_HOOK_URL="http://sms-bridge:8080/seerr/hook"
SMS_HOOK_TYPES=120

configure_sms_bridge() {
  log "Seerr: webhook notification agent → sms-bridge"
  [ -f "$SEERR_SETTINGS" ] || { warn "  settings.json missing — Seerr not initialized yet, skipping"; return; }
  local key secret
  key=$(seerr_key)
  [ -n "$key" ] || { warn "  Seerr API key unreadable in settings.json — skipping"; return; }
  secret=$(getenv SMS_BRIDGE_HOOK_SECRET)
  [ -n "$secret" ] || { warn "  SMS_BRIDGE_HOOK_SECRET blank in .env — run setup_script.sh first, skipping"; return; }
  up "$SEERR/api/v1/status" || { warn "  Seerr unreachable on :5055 — skipping"; return; }

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

# ─── Pterodactyl: location, node, and Wings' config.yml ──────────────────────
# Panel 1.x exposes artisan commands for everything up to the node, so all of it
# is reproducible from here. What stays manual in README Part 24: the admin user
# (needs 1Password, like Forgejo), egg import and server creation. `artisan list`
# has no egg, nest or allocation commands at all — egg import has no CLI and no
# API endpoint in 1.x, so it is genuinely UI-only. Allocations have no command
# either but are a flat table, so they are seeded by SQL below.
#
# Every artisan option falls through to an interactive prompt when omitted and
# there is no TTY here, so each command passes every flag explicitly.

PTERO_NODE_NAME=marlboro
PTERO_NODE_FQDN=marlboro.tail314238.ts.net
PTERO_ROOT=/mnt/tank/pterodactyl
# Wings' default game-server network is 172.18.0.0/16 — which marlboro_homelab
# already occupies. Overridden to a free range; 172.17 is docker0, 172.18 is
# homelab, 172.19 is coolify.
PTERO_SUBNET=172.22.0.0/16
PTERO_NETWORK=pterodactyl_nw
PTERO_BRIDGE=pterodactyl0
PTERO_GATEWAY=172.22.0.1
# Valheim: game port + query port (always game+1). 0.0.0.0 so the server answers
# on LAN, tailnet and the public router forward alike. Wings registers BOTH tcp and
# udp for every allocated port, so Valheim's UDP needs nothing special here.
PTERO_ALLOC_IP=0.0.0.0
PTERO_ALLOC_PORTS=(2456 2457)
PTERO_VALHEIM_SERVER=Valheim
# Crossplay: 1 = PlayFab relay, which hands out a join code and needs no router
# forward at all. 0 = Steam-only, where players direct-connect to
# marlboro-bc.duckdns.org:2456 and 2456-2457/UDP must be forwarded on the
# router. See README 24.8 before changing this.
PTERO_VALHEIM_CROSSPLAY=1
# SteamCMD update on boot. The game image's entrypoint runs
# `steamcmd +app_update ${SRCDS_APPID}` on every container start unless this is
# 0, so *restarting the server is the update mechanism* — there is no in-place
# updater. Hence the nightly restart schedule below: without it the server drifts
# behind the clients until someone restarts it by hand, and Valheim refuses
# connections from a client newer than the server.
PTERO_VALHEIM_AUTO_UPDATE=1
# The nightly restart that applies that update is NOT a panel schedule — see
# the removal below and README 24.17. This is only the name to remove.
PTERO_VALHEIM_SCHEDULE="Nightly update restart"

# Run a query against the panel DB. Used for existence checks only.
ptero_sql() {
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T pterodactyl-db \
    mariadb -N -B -u root -p"$(getenv PTERO_DB_ROOT_PASSWORD)" panel -e "$1" 2>/dev/null || true
}

ptero_artisan() {
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T pterodactyl-panel php artisan "$@"
}

# Panel client (ptlc_) API key — the only Pterodactyl API that reports whether a
# server is running, and so the Glance Valheim tile's data source (README 24.14).
# Account keys are user-scoped, so it belongs to the admin who owns the server.
#
# Panel 1.x has no artisan command for keys, but nothing here needs the UI: the
# secret is also recoverable, since api_keys holds the identifier in the clear and
# the remainder encrypted with APP_KEY. So an existing key is re-printed rather
# than a second one minted, and this stays idempotent.
#
# It deliberately does NOT write .env. setup_script.sh owns that file and rebuilds
# it from 1Password on every run, so a key written here would vanish on the next
# one; storing it in 1Password is the step that makes it stick.
configure_ptero_client_key() {
  log "Pterodactyl: client API key for the Glance tile"
  if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps --status running --services 2>/dev/null | grep -qx pterodactyl-panel; then
    warn "  pterodactyl-panel not running — skipping"; return
  fi

  local out state key envkey
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
        // forceFill, not create(): user_id and key_type are guarded against mass
        // assignment, and the model still validates on save.
        $key->forceFill([
            'user_id'     => $user->id,
            'key_type'    => \Pterodactyl\Models\ApiKey::TYPE_ACCOUNT,
            'identifier'  => \Pterodactyl\Models\ApiKey::generateTokenIdentifier(\Pterodactyl\Models\ApiKey::TYPE_ACCOUNT),
            'token'       => encrypt($secret),
            'memo'        => 'Glance Valheim tile',
            // Blank on purpose: Glance calls from the homelab Docker network, and
            // an allowlist that omits that subnet 403s the widget silently.
            'allowed_ips' => [],
        ])->save();
        echo "created " . $key->identifier . $secret . "\n";
    }
}
PHP
)" 2>/dev/null | tr -d '\r' | grep -E '^(no-admin|existing|created)' || true)

  read -r state key <<<"${out:-}"
  case "$state" in
    "")         warn "  key check returned nothing — check the panel"; return ;;
    no-admin)   warn "  no admin user yet — create one first (README 24.3)"; return ;;
    created)    warn "  minted a client API key for the Glance tile" ;;
  esac

  envkey=$(getenv PTERO_CLIENT_API_KEY)
  if [ "$envkey" = "$key" ]; then
    log "  client API key matches .env"
    return
  fi
  warn "  .env does not carry this key — the Valheim tile will show 'panel API 401'"
  warn "  store it in 1Password as item 'Marlboro NAS - Pterodactyl Client API', field api_token:"
  warn "    $key"
  warn "  then: ./setup_script.sh && docker compose up -d glance"
}

configure_pterodactyl() {
  log "Pterodactyl: location + node + wings config"
  local cfg="$SCRIPT_DIR/services/pterodactyl/wings-etc/config.yml"

  if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps --status running --services 2>/dev/null | grep -qx pterodactyl-panel; then
    warn "  pterodactyl-panel not running — skipping"; return
  fi
  # The entrypoint runs `migrate --seed --force` on boot; until it finishes the
  # tables we check don't exist yet.
  if [ -z "$(ptero_sql 'SHOW TABLES LIKE "nodes";')" ]; then
    warn "  panel migrations haven't finished yet — re-run once it's up"; return
  fi

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
    # scheme=http + proxy=0 => wings serves plain HTTP and the browser console
    # uses ws:// . daemonListeningPort is BOTH what wings binds internally and
    # what the panel puts in the console websocket URL, so it must match the
    # identity port mapping in docker-compose.yml (8092:8092).
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

  # config.yml carries the node's daemon token, which the panel encrypts with its
  # APP_KEY. Regenerate only when missing or when the token no longer matches the
  # panel, so a wings restart doesn't churn the file on every run.
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

  # Patch the keys the panel never emits. Wings' path defaults are literal
  # strings (/var/lib/pterodactyl/...), NOT derived from root_directory, so each
  # one is set explicitly — otherwise archives and world backups land on the
  # 30 GB root disk. Idempotent: re-running rewrites the same values.
  python3 - "$cfg" "$PTERO_ROOT" "$PTERO_SUBNET" "$PTERO_GATEWAY" <<'PY'
import sys, yaml
cfg, root, subnet, gw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = yaml.safe_load(open(cfg)) or {}
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
yaml.safe_dump(d, open(cfg, 'w'), default_flow_style=False, sort_keys=False)
PY
  log "  wings config.yml patched (root=$PTERO_ROOT, subnet=$PTERO_SUBNET)"

  # Allocations. Panel 1.x has no artisan command for these, and the Application
  # API needs a key that doesn't exist yet on a fresh install — so they go in by
  # SQL. The table is a flat (node_id, ip, port) list; INSERT..WHERE NOT EXISTS
  # keeps it idempotent without relying on a unique constraint.
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

  # Panel egg variables. These live in the panel DB, not the container
  # environment, so they are enforced here rather than in docker-compose.yml.
  # Server creation is a manual UI step, so do nothing when the row does not
  # exist yet.
  local pair vname vwant vcur vrow
  for pair in "ENABLE_CROSSPLAY=$PTERO_VALHEIM_CROSSPLAY" \
              "AUTO_UPDATE=$PTERO_VALHEIM_AUTO_UPDATE"; do
    vname=${pair%%=*}; vwant=${pair#*=}
    vrow=$(ptero_sql "SELECT sv.id FROM server_variables sv
                        JOIN egg_variables ev ON ev.id = sv.variable_id
                        JOIN servers s        ON s.id  = sv.server_id
                      WHERE ev.env_variable='$vname'
                        AND s.name='$PTERO_VALHEIM_SERVER' LIMIT 1;")
    if [ -z "$vrow" ]; then
      log "  no $PTERO_VALHEIM_SERVER server yet - skipping $vname"
      continue
    fi
    vcur=$(ptero_sql "SELECT variable_value FROM server_variables WHERE id=$vrow;")
    if [ "$vcur" = "$vwant" ]; then
      log "  $vname already $vwant"
    else
      ptero_sql "UPDATE server_variables SET variable_value='$vwant' WHERE id=$vrow;" >/dev/null
      warn "  $vname $vcur -> $vwant; restart the Valheim server to apply it"
    fi
  done

  # The nightly restart that keeps that update flowing is deliberately NOT a
  # panel schedule. The panel scheduler can restart on a cron, but its only
  # precondition is `only_when_online`, which just asks Wings whether the process
  # is up — Pterodactyl has no game-query support and so exposes no player count
  # anywhere. Restarting on top of a live session costs up to BACKUP_INTERVAL
  # (1800s) of world state, so the trigger lives in the valheim-autoupdate
  # container instead (README 24.17), which reads the count off the server's own
  # console line. A leftover panel schedule would restart a second time, so it is
  # removed here rather than merely left alone.
  local sched_id
  sched_id=$(ptero_sql "SELECT s.id FROM schedules s
                          JOIN servers sv ON sv.id = s.server_id
                        WHERE sv.name='$PTERO_VALHEIM_SERVER'
                          AND s.name='$PTERO_VALHEIM_SCHEDULE' LIMIT 1;")
  if [ -n "$sched_id" ]; then
    ptero_sql "DELETE FROM tasks WHERE schedule_id=$sched_id;" >/dev/null
    ptero_sql "DELETE FROM schedules WHERE id=$sched_id;" >/dev/null
    warn "  removed panel schedule '$PTERO_VALHEIM_SCHEDULE' - valheim-autoupdate owns the restart"
  else
    log "  no panel restart schedule (valheim-autoupdate owns it)"
  fi

  # Game-container network. Wings creates this itself when it is missing, and it
  # creates it with IPv6 enabled (ULA fdba:17c8:6c94::/64). This LAN has no IPv6
  # egress, so a game container holding a v6 address sends Valheim's public-IP
  # probe into a hot loop against ipv6.icanhazip.com / api6.ipify.org: ~90 log
  # lines per second and half a core, with the PlayFab registration left without
  # an IP (README 24.13). Pre-creating it v4-only avoids that, because wings
  # uses an existing network as it finds it.
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
    # Recreating it means detaching every game container, so this is a warning
    # rather than something the script does on its own.
    warn "  $PTERO_NETWORK has IPv6 enabled; stop all game servers, then run"
    warn "    docker network rm $PTERO_NETWORK && ./setup_services.sh && docker compose restart wings"
  else
    log "  $PTERO_NETWORK exists (IPv4-only)"
  fi

  log "  restart wings to pick up config changes: docker compose restart wings"
}

# ─── Nginx Proxy Manager: proxy hosts + Let's Encrypt certs ──────────────────
# Reconcile proxy hosts + their DNS-01 (DuckDNS) certs from the declarative list.
# Creates missing cert + host, skips existing (manual tweaks survive). NPM must
# be up on :81 with its admin creds set; cert issuance needs DuckDNS reachable.
#
# Format: domain | forward_host | forward_port | websockets | ssl_forced [| snippet]
# Host-networked / host-published services (Jellyfin, Plex, Coolify, the apex)
# are reached via the LAN IP; bridge services by container name. Keep in sync
# when exposing a new service externally.
#
# The optional 6th field names an nginx snippet from npm_advanced_config below.
NPM_HOSTS=(
  "marlboro-bc.duckdns.org|192.168.0.10|8096|true|true"        # apex → Jellyfin
  "jellyfin.marlboro-bc.duckdns.org|192.168.0.10|8096|true|false"
  "plex.marlboro-bc.duckdns.org|192.168.0.10|32400|true|true"
  "seerr.marlboro-bc.duckdns.org|seerr|5055|true|false"
  "git.marlboro-bc.duckdns.org|forgejo|3000|true|false"
  "coolify.marlboro-bc.duckdns.org|192.168.0.10|8000|true|true"
  "sms.marlboro-bc.duckdns.org|sms-bridge|8080|false|true|sms-inbound-only"
)

# Optional per-host nginx snippet, selected by the 6th NPM_HOSTS field.
#
# NPM omits its own default "location /" block whenever advanced_config contains the
# string "location" — so a snippet that opens one MUST supply the proxy_pass itself.
# That is exactly what we want here: sms-bridge exposes /twilio/inbound (Twilio),
# /seerr/hook (shared secret) and /healthz, and only the first has any business being
# on the public internet. Everything else 404s at the edge, so the hook and health
# endpoints stay LAN/tailnet-only even though the hostname is public.
npm_advanced_config() {
  case "$1" in
    sms-inbound-only) cat <<'NGINX'
location = /twilio/inbound {
    # Resolve the upstream at REQUEST time, not config-load time: a literal
    # proxy_pass hostname makes nginx refuse to start when the container is down,
    # which would take every other proxy host (Jellyfin included) with it. Via a
    # variable + Docker's embedded DNS, a dead sms-bridge is just a 502 here.
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

# ─── Run ─────────────────────────────────────────────────────────────────────
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

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Service reconcile complete."
echo "  Re-run any time — it converges, never clobbers manual edits."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
