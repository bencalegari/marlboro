#!/usr/bin/env bash
#
# Catch the Watchtower-fenced containers up to the tags pinned in
# docker-compose.yml.
#
#   usage: ./upgrade_fenced.sh [pterodactyl|immich|all]   (default: all)
#
# Thirteen services carry com.centurylinklabs.watchtower.enable=false on
# purpose. Two groups of them hold real state and need a careful, ordered
# restart rather than an unattended one:
#
#   pterodactyl  wings supervises live game-server containers and must never be
#                recreated underneath them; the panel applies Laravel
#                migrations on boot.
#   immich       ships breaking DB migrations across majors; server and
#                machine-learning must move in lockstep.
#
# That fence is correct, but it means these images never pick up base-image
# patches on their own. This script does that by hand, in dependency order,
# with a verified backup and a hard stop on the first failure.
#
# IMPORTANT: this only catches containers up to the tag ALREADY pinned in
# docker-compose.yml. It never bumps a version. Moving immich v3.2.x -> v3.3,
# or panel v1.15 -> v1.16, stays a deliberate act done after reading release
# notes -- which is the whole reason these are fenced.
#
# Safe to re-run. Every step is idempotent; if the images are already current
# the pulls are no-ops and Compose skips the recreates.

set -euo pipefail

# cron hands over a minimal PATH that usually lacks docker.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

COMPOSE_DIR="/home/bcalegari/marlboro"
BACKUP_ROOT="/mnt/tank/backups"
NTFY_URL="http://192.168.0.10:8194/marlboro-drift"
STAMP="$(date +%Y-%m-%d-%H%M)"
LOG_DIR="${BACKUP_ROOT}/fenced-upgrades"
LOG="${LOG_DIR}/upgrade-${STAMP}.log"

TARGET="${1:-all}"
GROUP="preflight"   # updated as we go, so failures name the right group

PTERO_SERVICES=(pterodactyl-db pterodactyl-cache pterodactyl-panel wings)
IMMICH_SERVICES=(immich-postgres immich-server immich-machine-learning)

# Note: immich-redis is deliberately NOT here. It carries scope=homelab, so
# Watchtower already updates it on the nightly run.

# ---------------------------------------------------------------- reporting --

notify() {
  # $1 = title, $2 = body, $3 = priority, $4 = tags
  curl -fsS --max-time 15 \
    -H "Title: $1" \
    -H "Priority: ${3:-default}" \
    -H "Tags: ${4:-gear}" \
    -d "$2" \
    "$NTFY_URL" >/dev/null 2>&1 || echo "WARN: ntfy publish failed" >&2
}

fail() {
  local msg="$1"
  echo "FAILED [${GROUP}]: ${msg}"
  notify "Fenced upgrade FAILED (${GROUP})" \
    "${msg}

The ${GROUP} stack may be partially upgraded -- check it before relying on it.
Log: ${LOG}
Backups: ${BACKUP_ROOT}" \
    "high" "rotating_light,x"
  exit 1
}

trap 'fail "Aborted at line ${LINENO}. See log for the failing command."' ERR

wait_healthy() {
  # $1 = container, $2 = attempts, $3 = sleep seconds
  local c="$1" tries="${2:-60}" nap="${3:-5}"
  echo "waiting for ${c} health..."
  for _ in $(seq 1 "$tries"); do
    [ "$(docker inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && return 0
    sleep "$nap"
  done
  fail "${c} never became healthy"
}

show_images() {
  for s in "$@"; do
    printf '  %-26s %s\n' "$s" \
      "$(docker inspect "$s" --format '{{.Config.Image}} {{.Image}}' 2>/dev/null || echo 'NOT RUNNING')"
  done
}

# ----------------------------------------------------------------- preflight --

case "$TARGET" in
  pterodactyl|immich|all) ;;
  *) echo "usage: $0 [pterodactyl|immich|all]" >&2; exit 2 ;;
esac

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

echo "=== fenced-image upgrade (${TARGET}) -- ${STAMP} ==="

cd "$COMPOSE_DIR" || fail "compose dir ${COMPOSE_DIR} not reachable"
[ -f docker-compose.yml ] || fail "docker-compose.yml not found in ${COMPOSE_DIR}"
[ -f .env ] || fail ".env not found -- cannot read DB credentials"
mountpoint -q /mnt/tank || fail "/mnt/tank is not mounted -- refusing to run without a backup target"
docker info >/dev/null 2>&1 || fail "docker daemon not reachable"

# ------------------------------------------------------------- pterodactyl --

upgrade_pterodactyl() {
  GROUP="pterodactyl"
  local dir="${BACKUP_ROOT}/pterodactyl"
  mkdir -p "$dir"

  echo
  echo "################ pterodactyl ################"
  echo "--- before ---"
  show_images "${PTERO_SERVICES[@]}"

  local root_pw panel_tables
  root_pw="$(grep -E '^PTERO_DB_ROOT_PASSWORD=' .env | cut -d= -f2-)"
  [ -n "$root_pw" ] || fail "PTERO_DB_ROOT_PASSWORD missing from .env"

  local games
  games="$(docker ps --format '{{.Names}}' --filter 'name=^[0-9a-f-]{36}$' || true)"
  if [ -n "$games" ]; then
    echo "NOTE: game server containers running (they survive a wings restart):"
    echo "$games"
  fi

  echo "--- backup ---"
  # Deliberately no --routines here. If a previous engine bump left mysql.proc
  # stale, --routines aborts the dump; a plain dump always succeeds and is what
  # we would actually restore from. The routine-aware dump runs after
  # mariadb-upgrade, as a health check.
  docker exec -e MYSQL_PWD="$root_pw" pterodactyl-db \
    mariadb-dump -uroot --single-transaction --databases panel 2>/dev/null \
    | gzip > "${dir}/panel-db-pre-${STAMP}.sql.gz" \
    || fail "panel DB dump failed"

  gzip -t "${dir}/panel-db-pre-${STAMP}.sql.gz" || fail "panel DB dump is corrupt"
  # grep -c, not grep -q: -q closes the pipe on first match, which SIGPIPEs
  # zcat and trips `set -o pipefail` on any dump large enough that zcat is
  # still writing. -c reads the whole stream.
  panel_tables="$(zcat "${dir}/panel-db-pre-${STAMP}.sql.gz" | grep -c '^CREATE TABLE' || true)"
  [ "${panel_tables:-0}" -gt 0 ] \
    || fail "panel DB dump contains no tables -- refusing to proceed"
  echo "db dump ok: $(du -h "${dir}/panel-db-pre-${STAMP}.sql.gz" | cut -f1), ${panel_tables} tables"

  tar czf "${dir}/panel-config-pre-${STAMP}.tar.gz" \
    -C services pterodactyl/panel-var pterodactyl/wings-etc pterodactyl/egg-valheim.json \
    || fail "panel/wings config backup failed"
  echo "config backup ok"

  echo "--- pull ---"
  docker compose pull "${PTERO_SERVICES[@]}" || fail "image pull failed"

  # 1. Database first, then reconcile its system tables. A MariaDB engine bump
  #    leaves mysql.* at the old layout until mariadb-upgrade runs; the symptom
  #    is subtle (only --routines dumps break), so this is not optional. This
  #    is what bit romm-db.
  echo "--- pterodactyl-db ---"
  docker compose up -d pterodactyl-db || fail "pterodactyl-db failed to start"
  wait_healthy pterodactyl-db 60 5

  docker exec -e MYSQL_PWD="$root_pw" pterodactyl-db mariadb-upgrade -uroot \
    || fail "mariadb-upgrade failed"
  echo "mariadb-upgrade ok"

  docker exec -e MYSQL_PWD="$root_pw" pterodactyl-db \
    mariadb-dump -uroot --single-transaction --routines --triggers --databases panel \
    >/dev/null 2>&1 \
    || fail "post-upgrade routine-aware dump still failing -- system tables not reconciled"
  echo "post-upgrade dump verification ok"

  # 2. Cache. Holds sessions and the job queue only; both rebuild on reconnect.
  echo "--- pterodactyl-cache ---"
  docker compose up -d pterodactyl-cache || fail "pterodactyl-cache failed to start"
  wait_healthy pterodactyl-cache 30 3

  # 3. Panel. Applies Laravel migrations on boot -- what the backup is for.
  echo "--- pterodactyl-panel ---"
  docker compose up -d pterodactyl-panel || fail "pterodactyl-panel failed to start"
  wait_healthy pterodactyl-panel 60 5

  # 4. Wings last, so it reattaches to a panel that is already up.
  echo "--- wings ---"
  docker compose up -d wings || fail "wings failed to start"
  sleep 20
  [ "$(docker inspect wings --format '{{.State.Status}}')" = running ] || fail "wings is not running"

  echo "--- after ---"
  show_images "${PTERO_SERVICES[@]}"

  # Wings reattaches to running containers rather than recreating them, so
  # anything that was playing should still be playing.
  local still_up
  still_up="$(docker ps --format '{{.Names}}' --filter 'name=^[0-9a-f-]{36}$' || true)"
  if [ -n "$games" ] && [ -z "$still_up" ]; then
    fail "game server containers were running before the upgrade but are gone now"
  fi
  PTERO_GAMES_UP="${still_up:-none were running}"

  docker exec pterodactyl-db mariadb --version
  docker exec pterodactyl-cache redis-server --version | head -1
  echo "pterodactyl: done"
}

# ------------------------------------------------------------------ immich --

upgrade_immich() {
  GROUP="immich"
  local dir="${BACKUP_ROOT}/immich"
  mkdir -p "$dir"

  echo
  echo "################ immich ################"
  echo "--- before ---"
  show_images "${IMMICH_SERVICES[@]}"

  # Asset count is the integrity check: it must not change across a patch-level
  # catch-up. If it does, something migrated that should not have.
  local assets_before immich_tables
  assets_before="$(docker exec immich-postgres psql -U immich -d immich -tAc 'select count(*) from asset' 2>/dev/null | tr -d '[:space:]')"
  [ -n "$assets_before" ] || fail "could not read asset count from immich-postgres"
  echo "assets before: ${assets_before}"

  echo "--- backup ---"
  docker exec immich-postgres pg_dump -U immich -d immich --clean --if-exists 2>/dev/null \
    | gzip > "${dir}/immich-db-pre-${STAMP}.sql.gz" \
    || fail "immich pg_dump failed"

  gzip -t "${dir}/immich-db-pre-${STAMP}.sql.gz" || fail "immich pg_dump is corrupt"
  # See the note in upgrade_pterodactyl: -c, never -q, on a piped dump.
  immich_tables="$(zcat "${dir}/immich-db-pre-${STAMP}.sql.gz" | grep -c '^CREATE TABLE' || true)"
  [ "${immich_tables:-0}" -gt 0 ] \
    || fail "immich pg_dump contains no tables -- refusing to proceed"
  echo "db dump ok: $(du -h "${dir}/immich-db-pre-${STAMP}.sql.gz" | cut -f1), ${immich_tables} tables"

  echo "--- pull ---"
  docker compose pull "${IMMICH_SERVICES[@]}" || fail "image pull failed"

  # 1. Postgres first so the server comes up against a settled DB.
  #    No engine-upgrade step here: the tag pins pg14 to match the on-disk
  #    data, and a postgres MAJOR bump needs pg_upgrade, never a tag swap.
  echo "--- immich-postgres ---"
  docker compose up -d immich-postgres || fail "immich-postgres failed to start"
  wait_healthy immich-postgres 60 5

  # 2. Server and machine-learning together -- they must stay in lockstep.
  echo "--- immich-server + immich-machine-learning ---"
  docker compose up -d immich-server immich-machine-learning \
    || fail "immich server/ML failed to start"
  wait_healthy immich-server 90 5
  wait_healthy immich-machine-learning 60 5

  echo "--- after ---"
  show_images "${IMMICH_SERVICES[@]}"

  local assets_after
  assets_after="$(docker exec immich-postgres psql -U immich -d immich -tAc 'select count(*) from asset' 2>/dev/null | tr -d '[:space:]')"
  [ -n "$assets_after" ] || fail "could not read asset count after upgrade"
  echo "assets after: ${assets_after}"
  [ "$assets_before" = "$assets_after" ] \
    || fail "asset count changed across the upgrade: ${assets_before} -> ${assets_after}"

  IMMICH_ASSETS="$assets_after"
  IMMICH_VERSION="$(curl -fsS --max-time 10 http://localhost:2283/api/server/version 2>/dev/null || echo 'unreadable')"
  echo "immich version endpoint: ${IMMICH_VERSION}"
  echo "immich: done"
}

# -------------------------------------------------------------------- run --

PTERO_GAMES_UP=""
IMMICH_ASSETS=""
IMMICH_VERSION=""

case "$TARGET" in
  pterodactyl) upgrade_pterodactyl ;;
  immich)      upgrade_immich ;;
  all)         upgrade_pterodactyl; upgrade_immich ;;
esac

GROUP="wrap-up"

# ------------------------------------------------------------------ disarm --

# A scheduled run is a one-shot. cron has no native one-shot, so the entry is
# pinned to a single date -- which means it would silently fire again a year
# from now. Remove it on success.
#
# Gated on FENCED_ONESHOT=1, which only the cron line sets. Without this gate a
# manual run would quietly cancel a scheduled one, which is the opposite of
# what anyone running this by hand intends.
if [ "${FENCED_ONESHOT:-0}" = 1 ] && [ "$(crontab -l 2>/dev/null | grep -c 'upgrade_fenced.sh' || true)" -gt 0 ]; then
  if crontab -l 2>/dev/null | grep -v 'upgrade_fenced.sh' | crontab -; then
    echo "removed the one-shot crontab entry"
  else
    echo "WARN: could not remove the one-shot crontab entry -- remove it by hand"
  fi
fi

echo
echo "=== complete (${TARGET}) ==="

SUMMARY="Fenced images caught up to their pinned tags."
[ -n "$PTERO_GAMES_UP" ] && SUMMARY="${SUMMARY}

pterodactyl ok -- game servers up: ${PTERO_GAMES_UP}"
[ -n "$IMMICH_ASSETS" ] && SUMMARY="${SUMMARY}

immich ok -- ${IMMICH_ASSETS} assets intact
${IMMICH_VERSION}"

notify "Fenced upgrade OK (${TARGET})" \
  "${SUMMARY}

Log: ${LOG}" \
  "default" "white_check_mark"
