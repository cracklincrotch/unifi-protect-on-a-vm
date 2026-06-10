#!/bin/bash
###############################################################################
# postgres-vda.sh — Protect/Access postgres on vda while running, on the
# array at rest.
#
# WHY
#
# The protect/access postgres clusters live under /srv/postgresql, which is
# the recording array (/volume1/.srv/postgresql). The array is the durable,
# portable home — pull the disks and the database travels with the
# recordings, exactly where a real UNVR's postgres expects it. But the array
# can be slow spinning disks, and on a RAM-constrained VM the database
# working set will not stay cached.
#
# So while the VM runs, the clusters are served from vda — the OS disk, a
# qcow2 on the host's NVMe. A bind mount overlays a vda working copy onto
# /volume1/.srv/postgresql; postgres runs at NVMe speed; the array's real
# directory sits intact underneath. At every clean shutdown the bind is
# dropped and the working copy is rsync'd back onto the array, so the disks
# are always self-contained when powered off — no migrate-out step to
# forget.
#
# An unclean power loss simply drops the bind mount (mounts are not
# persistent); the array keeps the last clean-shutdown cluster — one session
# stale at worst, never absent, never a dangling pointer.
#
# DIRECTION OF TRUST
#
# vda is always authoritative while it has a copy. The array is seeded FROM
# vda at shutdown; vda is seeded from the array ONLY when vda is empty (a
# fresh VM, or vda rebuilt). A populated vda working copy is never
# overwritten — so an unclean stop (array stale, vda current) never regresses
# the database on the next boot.
#
# Driven by postgres-vda.service: ExecStart -> 'start' (seed-if-empty +
# bind), ExecStop -> 'stop' (unmount + rsync). Ordered after
# provision-storage, before postgresql.
###############################################################################
set -u

ARRAY_PG=/volume1/.srv/postgresql      # real cluster directory on the array
VDA_PG=/data/postgres-active           # working copy on vda (the OS disk)
VOLUME=/volume1

log() { echo "[postgres-vda] $*"; }

# A directory counts as holding a database copy only if it has VISIBLE
# entries. UniFi drops marker dotfiles (e.g. .uid_gid_checked) into these
# directories; `ls -A` counts those, which once made an effectively-empty
# vda look populated — the seed was skipped, the junk copy was bound over
# the real cluster, and a later stop would have rsync-deleted the array's
# copy to match.
has_cluster() {
    [ -n "$(find "$1" -mindepth 1 -maxdepth 1 -not -name '.*' -print -quit \
        2>/dev/null)" ]
}

# Nothing to do until the recording array exists. Pre-array, /srv is a plain
# directory on vda and postgres already runs on vda directly — no bind
# needed, and nowhere on the array to sync to.
if ! mountpoint -q "$VOLUME" 2>/dev/null; then
    log "no array mounted at $VOLUME — nothing to do"
    exit 0
fi

case "${1:-}" in
    start)
        mkdir -p "$VDA_PG" "$ARRAY_PG"
        # Seed vda from the array ONLY when vda has no copy yet. A populated
        # vda copy is authoritative and is never overwritten here.
        if ! has_cluster "$VDA_PG"; then
            if has_cluster "$ARRAY_PG"; then
                log "vda working copy empty — seeding from the array"
                rsync -aHAX --delete "$ARRAY_PG"/ "$VDA_PG"/ \
                    || { log "ERROR: seed from array failed"; exit 1; }
            else
                log "no database yet — fresh start on vda"
            fi
        fi
        # Overlay the vda working copy onto the array's postgres directory.
        if mountpoint -q "$ARRAY_PG" 2>/dev/null; then
            log "$ARRAY_PG already bind-mounted"
        else
            mount --bind "$VDA_PG" "$ARRAY_PG" \
                || { log "ERROR: bind mount failed"; exit 1; }
            log "bind-mounted $VDA_PG over $ARRAY_PG"
        fi
        ;;
    stop)
        # Make sure postgres is down so the working copy is quiescent. At
        # shutdown postgresql.service has already stopped (we are ordered
        # Before it); this also covers a manual stop of this unit.
        systemctl stop postgresql 2>/dev/null || true
        # Drop the bind so $ARRAY_PG resolves to the real array directory.
        if mountpoint -q "$ARRAY_PG" 2>/dev/null; then
            umount "$ARRAY_PG" 2>/dev/null \
                || umount -l "$ARRAY_PG" 2>/dev/null \
                || { log "WARNING: could not unmount $ARRAY_PG — not syncing"
                     exit 0; }
            log "unmounted bind at $ARRAY_PG"
        fi
        # Sync the vda working copy onto the array's real directory, so the
        # disks carry a current cluster when powered off.
        if has_cluster "$VDA_PG"; then
            log "syncing database onto the array..."
            if rsync -aHAX --delete "$VDA_PG"/ "$ARRAY_PG"/; then
                log "database synced to $ARRAY_PG"
            else
                log "WARNING: sync to the array failed"
            fi
        fi
        ;;
    *)
        echo "usage: $0 {start|stop}" >&2
        exit 64
        ;;
esac
exit 0
