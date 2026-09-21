#!/usr/bin/env bash
#
# Archive the Valheim world from the NVMe to the array, keeping a month of it.
#
# The world and its four rolling auto-backups all sit in one directory on one
# consumer SSD, which is also the boot drive. Those backups answer "the world
# got wrecked, put it back"; they answer nothing about losing the disk, and
# they only reach about a day back. This puts dated copies on /mnt/tank.
#
# It copies the newest Dedicated_backup_auto-* rather than the live world.
# Valheim commits a save by writing _main.<gen>.db2 and .fwl2 and then the .ok
# marker, but the .chunk files are rewritten in place, so a copy taken mid-save
# can catch a half-written chunk. An auto-backup directory is finished the
# moment it appears and is never touched again, so it is safe to read at any
# time. The cost is that an archive can trail the live world by up to the
# -backupshort interval, currently two hours.
#
# Runs unprivileged. Safe to rerun: an archive is named for its source, so a
# second run the same day sees the work is already done.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log()  { echo -e "\033[1;32m==>\033[0m $1" >&2; }
warn() { echo -e "\033[1;33mWARNING:\033[0m $1" >&2; }

WORLD_ROOT="${VALHEIM_WORLD_ROOT:-/var/lib/marlboro/valheim-worlds}"
ARCHIVE="${VALHEIM_ARCHIVE:-/mnt/tank/backups/valheim}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
NTFY_URL="${NTFY_URL:-http://localhost:8194}"
NTFY_TOPIC="${NTFY_TOPIC:-valheim}"

notify() {
  # A backup that fails quietly is the same as no backup. Never let the
  # notification itself be what breaks the run.
  curl -fsS -m10 -H "Title: Valheim backup failed" -H "Priority: high" -H "Tags: warning" \
    -d "$1" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

fail() {
  echo -e "\033[1;31mERROR:\033[0m $1" >&2
  notify "$1"
  exit 1
}

for bin in rsync curl; do command -v "$bin" >/dev/null || fail "$bin not found."; done
[ -d "$WORLD_ROOT" ] || fail "$WORLD_ROOT does not exist — is the world mounted?"

# --- pick a source ------------------------------------------------------

source_dir=$(find "$WORLD_ROOT" -maxdepth 1 -type d -name 'Dedicated_backup_auto-*' \
  | sort | tail -1)
if [ -z "$source_dir" ]; then
  log "no auto-backup in $WORLD_ROOT yet — nothing consistent to archive"
  exit 0
fi

stamp=${source_dir##*Dedicated_backup_auto-}
dest="$ARCHIVE/world-$stamp"

if [ -d "$dest" ]; then
  log "$stamp is already archived — nothing to do"
  exit 0
fi

# --- copy ---------------------------------------------------------------

mkdir -p "$ARCHIVE"
rm -rf "$dest.partial"
rsync -a "$source_dir/" "$dest.partial/" || fail "rsync of $source_dir failed"

# A world is only restorable with its commit marker and the matching pair it
# points at, so check those before calling the archive good.
generation=$(find "$dest.partial" -maxdepth 1 -name '_main.*.ok' -printf '%f\n' \
  | sed -e 's/^_main\.//' -e 's/\.ok$//' | sort -n | tail -1)
[ -n "$generation" ] || fail "no _main.<gen>.ok marker in $source_dir — refusing to keep it"
for suffix in db2 fwl2; do
  [ -s "$dest.partial/_main.$generation.$suffix" ] \
    || fail "_main.$generation.$suffix missing or empty — refusing to keep the archive"
done

src_count=$(find "$source_dir" -type f | wc -l)
dst_count=$(find "$dest.partial" -type f | wc -l)
[ "$src_count" -eq "$dst_count" ] \
  || fail "copied $dst_count files but the source has $src_count"

mv "$dest.partial" "$dest"
ln -sfn "$dest" "$ARCHIVE/latest"
log "archived $stamp — $(du -sh "$dest" | cut -f1), generation $generation, $dst_count files"

# --- prune --------------------------------------------------------------

# Dated by name rather than mtime, so rsync's timestamp preservation and any
# later tinkering in the directory cannot confuse what is old.
cutoff=$(date -u -d "$RETENTION_DAYS days ago" +%Y%m%d)
kept=0 pruned=0
for archived in "$ARCHIVE"/world-*; do
  [ -d "$archived" ] || continue
  day=${archived##*/world-}; day=${day%%-*}
  if [ "$day" -lt "$cutoff" ]; then
    rm -rf "$archived"
    pruned=$(( pruned + 1 ))
  else
    kept=$(( kept + 1 ))
  fi
done
[ "$pruned" -gt 0 ] && log "pruned $pruned archive(s) older than ${RETENTION_DAYS}d"

# Pruning everything would mean the clock or the naming is wrong, not that the
# backups expired. Say so loudly rather than leaving an empty archive.
[ "$kept" -gt 0 ] || fail "pruning left no archives in $ARCHIVE — check the system clock"

log "$kept archive(s) in $ARCHIVE, $(df -h "$ARCHIVE" | tail -1 | awk '{print $4}') free"
