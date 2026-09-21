#!/usr/bin/env bash
#
# Move the Valheim world off the SMR array and onto the NVMe root filesystem.
#
# The world lives inside the Pterodactyl volume on /mnt/tank, which is four
# ST8000DM004 shingled drives. Saves are small but write-heavy, and the chunk
# write scales with the number of players: roughly 800ms with five online and
# nearly three seconds with nine. The files are not fragmented, so this is the
# drives' own write latency rather than anything btrfs is doing.
#
# Rather than relocate the whole server, this bind mounts an NVMe directory
# over worlds_local. The Valheim binary and the SteamCMD tree stay on the array
# where their size belongs and their read pattern is harmless.
#
# Safe to rerun: it does nothing once the bind mount is in place.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log()  { echo -e "\033[1;32m==>\033[0m $1" >&2; }
warn() { echo -e "\033[1;33mWARNING:\033[0m $1" >&2; }
err()  { echo -e "\033[1;31mERROR:\033[0m $1" >&2; exit 1; }

NVME_ROOT="${VALHEIM_WORLD_ROOT:-/var/lib/marlboro/valheim-worlds}"
WINGS_URL="${WINGS_URL:-http://localhost:8092}"
WINGS_CONFIG="$SCRIPT_DIR/services/pterodactyl/wings-etc/config.yml"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
STATE_FILE="$SCRIPT_DIR/services/valheim-autoupdate/state/autoupdate.json"
STOP_TIMEOUT=180
START_TIMEOUT=300
# systemd-run names the transient timer that fires this at 03:00. Clearing it
# on success keeps a one-time migration from lingering as a daily no-op.
SELF_TIMER="${SELF_TIMER:-valheim-world-nvme.timer}"

[ "$(id -u)" -eq 0 ] || err "run this with sudo — it edits /etc/fstab and mounts."
for bin in curl jq rsync python3 docker; do
  command -v "$bin" >/dev/null || err "$bin not found."
done

UUID=$(grep -oE 'VALHEIM_UUID=[0-9a-f-]+' "$COMPOSE_FILE" | head -1 | cut -d= -f2)
[ -n "$UUID" ] || err "could not read VALHEIM_UUID from $COMPOSE_FILE"

VOLUME="/mnt/tank/pterodactyl/volumes/$UUID"
WORLDS="$VOLUME/.config/unity3d/IronGate/Valheim/worlds_local"
ROLLBACK="$WORLDS.pre-nvme"
DOCKER_DROPIN=/etc/systemd/system/docker.service.d/wait-for-valheim-world.conf

dropin_content() { printf '[Unit]\nRequiresMountsFor=%s\n' "$WORLDS"; }

TOKEN=$(grep -m1 '^token:' "$WINGS_CONFIG" | cut -d: -f2- | tr -d ' ')
[ -n "$TOKEN" ] || err "no token in $WINGS_CONFIG"

wings() {
  local method="$1" path="$2" payload="${3:-}"
  if [ -n "$payload" ]; then
    curl -fsS -m15 -X "$method" "$WINGS_URL$path" \
      -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' \
      -H 'Content-Type: application/json' -d "$payload"
  else
    curl -fsS -m15 -X "$method" "$WINGS_URL$path" \
      -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json'
  fi
}

server_state() { wings GET "/api/servers/$UUID" | jq -r '.state // "unknown"'; }

wait_for_state() {
  local want="$1" deadline=$(( SECONDS + $2 )) seen
  while [ "$SECONDS" -lt "$deadline" ]; do
    seen=$(server_state 2>/dev/null || echo unreachable)
    [ "$seen" = "$want" ] && return 0
    sleep 5
  done
  return 1
}

players_online() {
  # Same signal the autoupdate guard uses: the newest "Connections N" line the
  # server prints every ten minutes. An absent or stale line means unknown, and
  # unknown is treated as occupied so the migration never races live players.
  # Valheim stamps its log in UTC regardless of the container's TZ.
  wings GET "/api/servers/$UUID/logs?size=200" | jq -r '.data[]?' | python3 -c '
import re, sys, time
from datetime import datetime, timezone

pattern = re.compile(r"^(\d\d/\d\d/\d{4} \d\d:\d\d:\d\d): +Connections (\d+)")
hits = [m for line in sys.stdin for m in [pattern.search(line)] if m]
if not hits:
    print("unknown")
else:
    stamp, count = hits[-1].groups()
    seen = datetime.strptime(stamp, "%m/%d/%Y %H:%M:%S").replace(tzinfo=timezone.utc)
    age = time.time() - seen.timestamp()
    print("unknown" if age > 1500 else count)
'
}

mark_guard_done() {
  # The autoupdate guard restarts the server at 03:00 when it is empty, and we
  # are about to restart it ourselves inside that same window. Claiming the day
  # stops the two from fighting; SteamCMD still runs on the way back up.
  [ -f "$STATE_FILE" ] || return 0
  python3 - "$STATE_FILE" <<'PY' || true
import json, sys, time
from datetime import date
path = sys.argv[1]
try:
    with open(path) as fh:
        state = json.load(fh)
except (OSError, ValueError):
    state = {}
state["done_for"] = date.today().isoformat()
state["status"] = "restarted for the NVMe world migration"
state["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(state, fh)
import os
os.replace(tmp, path)
PY
}

fstab_line() {
  printf '%s %s none bind,x-systemd.requires-mounts-for=/mnt/tank 0 0\n' "$NVME_ROOT" "$WORLDS"
}

ensure_fstab() {
  local reload=0
  if grep -qF " $WORLDS none bind," /etc/fstab; then
    log "  fstab entry exists"
  else
    cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    fstab_line >> /etc/fstab
    reload=1
    log "  fstab entry added"
  fi
  # Docker already refuses to start before /mnt/tank. The world now lives on a
  # second mount, and a container built before it lands would hand Valheim an
  # empty directory, which it answers by generating a brand new world. Ordering
  # docker behind this mount too is what stops that.
  if [ "$(cat "$DOCKER_DROPIN" 2>/dev/null)" != "$(dropin_content)" ]; then
    install -d -m 0755 "$(dirname "$DOCKER_DROPIN")"
    dropin_content > "$DOCKER_DROPIN"
    chmod 0644 "$DOCKER_DROPIN"
    reload=1
    log "  docker.service ordered behind the world mount"
  fi
  [ "$reload" -eq 1 ] && systemctl daemon-reload || true
}

# --- preconditions ------------------------------------------------------

if mountpoint -q "$WORLDS"; then
  log "world already on NVMe ($NVME_ROOT) — nothing to do"
  ensure_fstab
  exit 0
fi

if [ ! -d "$VOLUME" ]; then
  log "no Valheim volume at $VOLUME yet — nothing to move"
  exit 0
fi

# A server that has never booted has no worlds_local. There is nothing to copy
# and no reason to stop anything: mount first and let Valheim create the world
# on NVMe to begin with.
owner=$(stat -c '%u:%g' "$VOLUME")
FRESH=0
[ -d "$WORLDS" ] || FRESH=1

# A leftover rollback means an earlier run stopped halfway. Moving the world
# aside again would bury it inside that directory, so stop and let a person look.
[ -e "$ROLLBACK" ] \
  && err "$ROLLBACK already exists — an earlier run did not finish, resolve it by hand"

probe="$NVME_ROOT"
while [ ! -d "$probe" ]; do probe=$(dirname "$probe"); done
avail=$(df -Pk "$probe" | tail -1 | awk '{print $4}')
if [ "$FRESH" -eq 1 ]; then needed=65536; else needed=$(du -sk "$WORLDS" | cut -f1); fi
# Four times the world leaves room for it to grow and for a save's temporary
# clone, which is written alongside the live chunks before the rename.
[ "$avail" -gt $(( needed * 4 )) ] \
  || err "need $(( needed * 4 / 1024 ))MB on $probe, only $(( avail / 1024 ))MB free"

online=$(players_online 2>/dev/null || echo unknown)
if [ "${FORCE:-0}" != "1" ] && [ "$online" != "0" ]; then
  log "$online player(s) online — not migrating, will retry on the next run"
  exit 0
fi

# --- stop ---------------------------------------------------------------

started_state=$(server_state 2>/dev/null || echo unreachable)
if [ "$started_state" = "running" ]; then
  log "Valheim: stopping the server"
  wings POST "/api/servers/$UUID/power" '{"action":"stop"}' >/dev/null
  wait_for_state offline "$STOP_TIMEOUT" \
    || err "server did not stop within ${STOP_TIMEOUT}s — nothing has been moved"
fi
log "Valheim: server is $(server_state 2>/dev/null || echo unreachable)"

# --- copy ---------------------------------------------------------------

install -d -m 0755 "$(dirname "$NVME_ROOT")"
install -d -o "${owner%:*}" -g "${owner#*:}" -m 0755 "$NVME_ROOT"
if [ "$FRESH" -eq 1 ]; then
  log "Valheim: no existing world — mounting NVMe before first boot"
else
  log "Valheim: copying the world to $NVME_ROOT"
  rsync -a --delete "$WORLDS/" "$NVME_ROOT/"
  diff -r -q "$WORLDS" "$NVME_ROOT" >/dev/null \
    || err "copy verification failed — the original is untouched at $WORLDS"
  log "  $(du -sh "$NVME_ROOT" | cut -f1) copied and verified"
fi

# --- swap ---------------------------------------------------------------

restore() {
  warn "rolling back to the array copy"
  umount "$WORLDS" 2>/dev/null || true
  sed -i "\|^$NVME_ROOT $WORLDS none bind,|d" /etc/fstab
  rm -f "$DOCKER_DROPIN"
  systemctl daemon-reload
  if [ -d "$ROLLBACK" ]; then
    rmdir "$WORLDS" 2>/dev/null || true
    mv "$ROLLBACK" "$WORLDS"
  fi
  [ "$started_state" = "running" ] \
    && wings POST "/api/servers/$UUID/power" '{"action":"start"}' >/dev/null 2>&1 || true
}

log "Valheim: mounting the NVMe copy over the array path"
[ "$FRESH" -eq 1 ] || mv "$WORLDS" "$ROLLBACK"
install -d -o "${owner%:*}" -g "${owner#*:}" -m 0755 "$WORLDS"
ensure_fstab
mount "$WORLDS" || { restore; err "bind mount failed"; }
mountpoint -q "$WORLDS" || { restore; err "bind mount did not take"; }
[ "$FRESH" -eq 1 ] && log "  mounted" || log "  mounted; the array copy is kept at $ROLLBACK"

# Wings bind mounts /mnt/tank/pterodactyl with private propagation, so a mount
# created underneath it is invisible until its container is built again. The
# game container is recreated by the start below and picks the mount up on its
# own; wings needs the nudge or its file manager and backups see an empty world.
log "Valheim: recreating wings so it sees the new mount"
(cd "$SCRIPT_DIR" && docker compose -f "$COMPOSE_FILE" up -d --force-recreate wings) >/dev/null
for _ in $(seq 1 30); do
  server_state >/dev/null 2>&1 && break
  sleep 2
done

# --- start --------------------------------------------------------------

if [ "$started_state" = "running" ]; then
  mark_guard_done
  log "Valheim: starting the server"
  wings POST "/api/servers/$UUID/power" '{"action":"start"}' >/dev/null
  wait_for_state running "$START_TIMEOUT" || { restore; err "server did not come back up"; }
fi

log "Valheim: world storage is on NVMe"
log "  live:  $NVME_ROOT"
[ "$FRESH" -eq 1 ] || log "  rollback: $ROLLBACK (delete once a few saves have landed cleanly)"
log "  watch: docker logs -f $UUID | grep 'World save'"

systemctl stop "$SELF_TIMER" 2>/dev/null || true
