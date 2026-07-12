#!/bin/bash
###############################################################################
# protect-backup-to-array.sh — mirror UniFi OS whole-system backups onto the
# recording array so they are durable and travel with the disks.
#
# unifi-core writes small config/adoption backups (protect + access + users,
# a few MB total — NOT recordings) to /data/unifi-core/backups, created by its
# own scheduled auto-backup or a manual UI backup. The recordings themselves
# already live on the array (raw), so config-backup + on-array recordings is the
# full, supported recovery set. This unit just copies those config backups onto
# the array. It is READ-ONLY with respect to the source and does no DB work.
###############################################################################
set -u

SRC=/data/unifi-core/backups
DST=/volume1/.srv/protect-config-backups
VOLUME=/volume1
KEEP="${KEEP:-30}"                        # newest N backup dirs to retain on the array

log() {
    echo "[protect-backup-to-array] $*"
    logger -t protect-backup-to-array "$*" 2>/dev/null || true
}

mountpoint -q "$VOLUME" 2>/dev/null || { log "array not mounted at $VOLUME — skipping"; exit 0; }
[ -d "$SRC" ] || { log "no source dir $SRC — nothing to mirror"; exit 0; }
mkdir -p "$DST"

# Additive mirror (NO --delete): the array is the long-term store and keeps
# backups even after unifi-core prunes its local copies.
if rsync -aHAX "$SRC"/ "$DST"/ 2>/dev/null; then
    log "mirrored $(find "$SRC" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) local backup(s) to $DST"
else
    log "WARNING: rsync mirror failed — leaving prior array copies intact"; exit 0
fi

# Retain only the newest $KEEP backup dirs on the array.
mapfile -t old < <(ls -1dt "$DST"/*/ 2>/dev/null | tail -n +$(( KEEP + 1 )))
for d in "${old[@]}"; do
    rm -rf "$d" && log "pruned old backup $(basename "$d")"
done
exit 0
