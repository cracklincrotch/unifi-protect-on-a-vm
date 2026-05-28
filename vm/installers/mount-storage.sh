#!/bin/bash
###############################################################################
# mount-storage.sh
#
# Helper to set up storage for the Protect VM. Handles three scenarios:
#
#   1. IMPORT: existing UNVR disks installed in the DAS — assemble the array,
#      detect its UUID, and configure fstab to mount it at /volume1.
#
#   2. POSTGRES MIGRATE: move postgres data clusters off the spinning RAID
#      and onto a dedicated SSD. Dramatically improves UI responsiveness when
#      searching faces or scrolling timeline.
#
#   3. STATUS: just show what's currently configured.
#
# WHY THIS SCRIPT EXISTS
#
# The fresh install (install-protect-baremetal.sh) creates a brand new
# storage array on a single disk. That works for testing but isn't what
# you want when migrating from a real UNVR — the UNVR's existing RAID
# already has your recordings and you want to preserve them.
#
# The import workflow:
#   1. Shut down the UNVR cleanly
#   2. Pull all four disks
#   3. Install them in the DAS
#   4. Boot the VM (start-protect-vm.sh resolves them by ATA serial)
#   5. Run this script with `import`
#
# mdadm assembles the existing RAID automatically using the disk
# superblocks. The challenge is that the array's name embedded in the
# superblock includes the original UNVR's hostname (e.g., "UniFi-NVR:3"),
# so on our VM the array comes up as /dev/md126 or /dev/md127 — NOT
# /dev/md3 like the install script created. We handle that by mounting
# via filesystem UUID instead of device name.
#
# WHY POSTGRES-MIGRATE EXISTS
#
# Protect's web UI responsiveness is dominated by postgres query speed.
# Face search, timeline scrubbing, smart detection lookups — all are
# postgres queries. When postgres lives on the same spinning RAID as the
# camera recordings, every query waits for the disks to seek between
# continuous write operations.
#
# Moving postgres to a dedicated SSD took our face search from 4+ minutes
# to under 2 seconds. The database working set is small (3-4GB) but the
# I/O pattern (many scattered small reads) is exactly what spinning disks
# handle worst.
#
# This script handles the migration safely: stops all services, copies
# data with rsync, updates fstab, restarts. Keeps the old data on the
# RAID as a backup until you're satisfied things work.
#
# Usage:
#   ./mount-storage.sh status
#   ./mount-storage.sh import
#   ./mount-storage.sh postgres-migrate <device>
#
# Flags:
#   --force, -f   Skip confirmation prompts. Use with care — this bypasses
#                 the "type YES" confirmation that protects against
#                 accidentally wiping an SSD with existing data. Intended
#                 for automation only.
#
# Run as root inside the VM.
###############################################################################

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

# Parse arguments. Any positional args land in POSITIONAL[], flags are
# extracted out. This lets the user put --force anywhere on the line:
#   ./mount-storage.sh postgres-migrate /dev/sde --force
#   ./mount-storage.sh --force postgres-migrate /dev/sde
FORCE=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --help|-h)
            sed -n '2,30p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

ACTION="${POSITIONAL[0]:-status}"
ARG1="${POSITIONAL[1]:-}"

###############################################################################
# Helpers
###############################################################################

# Simple yes/no prompt that defaults to no. Used before reversible or
# low-risk destructive operations. Skipped if --force was passed.
confirm() {
    local prompt="$1"
    if [ "$FORCE" -eq 1 ]; then
        echo "$prompt [forced — skipping confirmation]"
        return 0
    fi
    read -p "$prompt [y/N]: " response
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Strict confirmation prompt — requires the user to literally type YES in
# all caps. Used for operations that are destructive AND irreversible
# without a backup (formatting a disk with existing data, etc.). Skipped
# if --force was passed.
#
# The intent is to make accidental destruction nearly impossible: hitting
# Enter, hitting 'y' Enter, or anything else short of typing those three
# specific characters aborts.
confirm_strict() {
    local prompt="$1"
    if [ "$FORCE" -eq 1 ]; then
        echo "$prompt [forced — skipping confirmation]"
        return 0
    fi
    echo ""
    echo "$prompt"
    echo "This operation is DESTRUCTIVE and CANNOT BE UNDONE."
    echo "Type 'YES' (in all capitals) to proceed, or anything else to abort:"
    read -r response
    if [ "$response" = "YES" ]; then
        return 0
    fi
    echo "Aborted."
    return 1
}

# Strongly recommend a host-side snapshot before destructive operations.
# Snapshots are instant copy-on-write checkpoints of the VM disks; they're
# the fast rollback path if something breaks. The VM itself can't take
# the snapshot (the disk has to be idle for qemu-img to work safely), so
# we just remind the user.
#
# Skipped if --force was passed.
recommend_snapshot() {
    local description="$1"
    if [ "$FORCE" -eq 1 ]; then
        return 0
    fi
    cat <<EOF

==============================================
RECOMMENDED: Take a snapshot before proceeding
==============================================

About to: $description

This operation moves data between disks and modifies fstab. A snapshot
of the VM disks gives you a one-command rollback path if something goes
wrong. Snapshots are fast (the VM pauses for a few seconds), take no
extra space until data changes, and can be deleted later.

To take one — no VM shutdown required:
  1. Press Ctrl+C now to abort this script
  2. On the host:  ./snapshot.sh create-auto pre-storage-change
  3. The VM will pause ~2-5 seconds while the snapshot is taken
  4. Re-run this command

If you've already taken a snapshot — or accept the risk of no rollback —
press Enter to continue.

EOF
    read -r -p "Press Enter to continue: "
}

###############################################################################
# Action: STATUS
#
# Just shows what storage exists, how it's configured, and what's mounted.
# Useful for verifying state before/after the other commands.
###############################################################################

status() {
    echo "=============================================="
    echo "Storage Status"
    echo "=============================================="

    echo ""
    echo ">>> Block devices:"
    # lsblk shows the disk tree including filesystems, labels, and
    # current mount points. The most useful single command for
    # understanding storage state.
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null

    echo ""
    echo ">>> MD arrays:"
    # /proc/mdstat shows kernel's view of any MD (software RAID) arrays.
    # If you imported UNVR disks, both md126 (data) and md127 (UNVR's
    # boot partitions, which we don't use) will appear here.
    cat /proc/mdstat 2>/dev/null

    echo ""
    echo ">>> /etc/fstab volumes:"
    # Skip comments and blank lines, show what should mount at boot.
    grep -v "^#" /etc/fstab | grep -v "^$"

    echo ""
    echo ">>> /srv symlink:"
    # /srv should be a symlink to /volume1/.srv. If it's a directory
    # instead, something went wrong during install.
    ls -la /srv 2>/dev/null

    echo ""
    echo ">>> Postgres clusters:"
    # pg_lsclusters shows where each postgres cluster's data lives.
    # The 'access' and 'protect' clusters should be on /srv/postgresql
    # (which is the SSD if you ran postgres-migrate, or the RAID if not).
    # 'main' lives on /data which is the VM rootfs.
    pg_lsclusters 2>/dev/null || echo "    pg_lsclusters not available"
}

###############################################################################
# Action: IMPORT
#
# Assemble the RAID from disks imported from a UNVR, detect its UUID,
# configure fstab, ensure /srv symlink is correct.
###############################################################################

import() {
    echo "=============================================="
    echo "Import existing UNVR storage"
    echo "=============================================="

    echo ""
    echo ">>> Scanning for arrays..."
    # --scan looks at all disks for mdadm superblocks. Any unassembled
    # arrays with matching superblock UUIDs get auto-assembled. This is
    # how the UNVR's RAID comes online inside the VM without manual
    # device list management.
    mdadm --assemble --scan 2>/dev/null || true
    sleep 2

    cat /proc/mdstat

    echo ""
    echo ">>> Looking for the data array..."
    # The UNVR uses RAID10 across 4 disks for data and a small RAID1 for
    # the boot partitions. We want the bigger array — the data one.
    # Pick the largest md device.
    DATA_MD=$(lsblk -nrlpo NAME,SIZE,TYPE | \
              awk '$3=="raid0"||$3=="raid1"||$3=="raid5"||$3=="raid10" {print $1, $2}' | \
              sort -k2 -h | tail -1 | awk '{print $1}')

    if [ -z "$DATA_MD" ]; then
        echo "ERROR: No RAID array found. Check that UNVR disks are connected."
        return 1
    fi

    echo "    Data array: $DATA_MD"

    # Newly assembled arrays from imported disks often come up as
    # 'auto-read-only'. Force read-write so we can mount and use them.
    mdadm --readwrite "$DATA_MD"

    # Get the ext4 UUID from inside the array. We use this in fstab
    # instead of the /dev/md12N device name because the device name
    # depends on the hostname in the mdadm superblock — which is the
    # original UNVR's hostname, not ours. The UUID is filesystem-level
    # and stable across imports.
    DATA_UUID=$(blkid -s UUID -o value "$DATA_MD")
    if [ -z "$DATA_UUID" ]; then
        echo "ERROR: Could not read UUID from $DATA_MD"
        return 1
    fi
    echo "    UUID: $DATA_UUID"

    # Mount the array. If already mounted, leave it.
    if mountpoint -q /volume1; then
        echo "    /volume1 already mounted"
    else
        mkdir -p /volume1
        mount UUID="$DATA_UUID" /volume1 2>/dev/null || mount "$DATA_MD" /volume1
    fi

    df -h /volume1

    # Sanity check: did we mount actual UNVR data, or some random other
    # array? UNVR data always has /volume1/.srv as the hidden root for
    # service data.
    if [ ! -d /volume1/.srv ]; then
        echo "ERROR: /volume1/.srv not found. Is this a UNVR data disk?"
        return 1
    fi

    # Update fstab. Remove any old /volume1 entries first to avoid
    # duplicates. Use the UUID so this works even if the array number
    # changes on next reboot.
    if grep -q "/volume1" /etc/fstab; then
        echo "    Removing old /volume1 entry from fstab"
        sed -i '/\/volume1/d' /etc/fstab
    fi
    echo "UUID=$DATA_UUID /volume1 ext4 defaults,nofail 0 2" >> /etc/fstab
    echo "    Added to fstab"

    # Ensure /srv is a symlink to /volume1/.srv. The UNVR ships /srv as
    # a symlink and Ubiquiti software depends on it. If /srv exists as
    # a real directory, replace it.
    if [ ! -L /srv ] || [ "$(readlink /srv)" != "/volume1/.srv" ]; then
        rm -rf /srv
        ln -s /volume1/.srv /srv
        echo "    /srv -> /volume1/.srv"
    fi

    echo ""
    echo "Import complete. You can now start the UniFi services:"
    echo "    systemctl start postgresql"
    echo "    systemctl start unifi-core ds ai-feature-console unifi-protect unifi-access"
}

###############################################################################
# Action: POSTGRES MIGRATE
#
# Move postgres data clusters from the spinning RAID to a dedicated disk.
# This is the single biggest UI performance improvement available.
###############################################################################

postgres_migrate() {
    local target_disk="${1:-}"

    echo "=============================================="
    echo "Migrate postgres data to dedicated disk"
    echo "=============================================="

    if [ -z "$target_disk" ]; then
        echo "Usage: $0 postgres-migrate <device>"
        echo ""
        echo "Available unused block devices:"
        # Find block devices with no filesystem and no mount point — these
        # are candidates for the migration target. Filter out the VM's
        # internal disks (vda), md arrays, loop devices, and CD/DVD (sr).
        lsblk -nrlpo NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | \
            awk '$3=="" && $4=="" && $1 !~ /^.dev.(vda|md|loop|sr)/ {print "    " $1, $2}'
        return 1
    fi

    if [ ! -b "$target_disk" ]; then
        echo "ERROR: $target_disk is not a block device"
        return 1
    fi

    # Recommend snapshot before any destructive work.
    recommend_snapshot "migrate postgres from /srv/postgresql to $target_disk"

    # Safety check: refuse to wipe a disk that already has data unless
    # the user explicitly confirms. Existing data is the bigger risk, so
    # we use the strict confirm here (type YES). A fresh, unformatted
    # disk gets the lighter touch.
    if blkid "$target_disk" >/dev/null 2>&1; then
        echo ""
        echo "WARNING: $target_disk already has a filesystem:"
        blkid "$target_disk" | sed 's/^/    /'
        confirm_strict "About to WIPE and REFORMAT $target_disk." || return 1
    else
        # Fresh disk — lighter confirmation since there's nothing to lose.
        confirm "Format $target_disk as ext4 and migrate postgres to it?" || return 1
    fi

    echo ""
    echo ">>> Stopping all UniFi services..."
    # Stop everything that might touch postgres. Order matters: stop the
    # apps first, then the database. Otherwise the apps log errors when
    # the database goes away.
    systemctl stop unifi-protect unifi-access ai-feature-console ds unifi-core ulp-go uid-agent 2>/dev/null || true
    systemctl stop postgresql.service 2>/dev/null || true

    # CRITICAL: Mask these services during migration. Systemd's restart
    # logic and Ubiquiti's wrapper scripts will otherwise restart things
    # mid-migration, causing rsync to copy a moving target or postgres
    # to start against the empty new disk.
    for svc in unifi-protect unifi-access ds ai-feature-console postgresql; do
        systemctl mask "${svc}.service" 2>/dev/null || true
    done
    sleep 3

    # Make sure no postgres processes are still running. They sometimes
    # take a few seconds to shut down cleanly. After 5 seconds, force.
    pkill -9 postgres 2>/dev/null || true
    sleep 2

    if pgrep postgres >/dev/null; then
        echo "ERROR: postgres still running after kill. Aborting."
        return 1
    fi

    echo ""
    echo ">>> Formatting $target_disk..."
    # Label the filesystem 'pgdata' so we can mount by label in fstab.
    # Labels are easier to track than UUIDs when reading fstab.
    # -F forces format even if it looks like there's a previous filesystem.
    mkfs.ext4 -F -L pgdata "$target_disk"

    echo ""
    echo ">>> Migrating postgres data..."
    mkdir -p /mnt/pgdata
    mount "$target_disk" /mnt/pgdata
    # rsync flags:
    #   -a: archive mode (preserves permissions, ownership, timestamps, etc.)
    #   -H: preserve hard links
    #   -A: preserve ACLs (important for postgres data files)
    #   -X: preserve extended attributes
    #   --info=progress2: show overall progress instead of per-file
    # We need all these flags because postgres relies on exact ownership
    # and permissions to start.
    rsync -aHAX --info=progress2 /srv/postgresql/ /mnt/pgdata/
    umount /mnt/pgdata
    # Tempdir is no longer needed; remove it so it doesn't sit around
    # looking like it might still hold data.
    rmdir /mnt/pgdata 2>/dev/null || true

    echo ""
    echo ">>> Backing up old data..."
    # Move the old location aside rather than deleting it. This is your
    # safety net if postgres won't start on the new disk. Once everything
    # is verified working, you can remove this directory manually:
    #   rm -rf /srv/postgresql.old.*
    BACKUP_PATH="/srv/postgresql.old.$(date +%s)"
    mv /srv/postgresql "$BACKUP_PATH"
    echo "    Old data preserved at $BACKUP_PATH"

    echo ""
    echo ">>> Mounting new postgres disk..."
    mkdir -p /srv/postgresql
    # Clean up any old pgdata entries before adding the new one.
    sed -i '/pgdata/d' /etc/fstab
    echo "LABEL=pgdata /srv/postgresql ext4 defaults,nofail 0 2" >> /etc/fstab
    mount /srv/postgresql

    echo ""
    echo ">>> Unmasking and starting services..."
    # Restore service masking so they can start normally again.
    for svc in unifi-protect unifi-access ds ai-feature-console postgresql; do
        systemctl unmask "${svc}.service" 2>/dev/null || true
    done
    # Start postgres first so the apps have a database to connect to.
    systemctl start postgresql.service
    sleep 5
    systemctl start unifi-core ds ai-feature-console ulp-go uid-agent unifi-access unifi-protect

    echo ""
    echo "Postgres migration complete."
    echo "Old data preserved at $BACKUP_PATH ($(du -sh "$BACKUP_PATH" 2>/dev/null | awk '{print $1}'))"
    echo "Once you've confirmed everything works, delete it with:"
    echo "    rm -rf $BACKUP_PATH"
}

###############################################################################
# Execute
###############################################################################

case "$ACTION" in
    status) status ;;
    import) import ;;
    postgres-migrate) postgres_migrate "$ARG1" ;;
    *)
        echo "Usage: $0 [--force] <status|import|postgres-migrate [device]>"
        echo ""
        echo "Flags:"
        echo "  --force, -f   Skip confirmation prompts (use with care)"
        exit 1
        ;;
esac
