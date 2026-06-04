#!/bin/bash
###############################################################################
# mount-storage.sh
#
# Helper to set up storage for the Protect VM. Handles two scenarios:
#
#   1. IMPORT: existing UNVR disks installed in the DAS — assemble the array,
#      detect its UUID, and configure fstab to mount it at /volume1.
#
#   2. STATUS: just show what's currently configured.
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
# A NOTE ON POSTGRES PERFORMANCE
#
# Protect's web UI responsiveness is dominated by postgres query speed
# (face search, timeline scrubbing, smart-detection lookups), and the
# array's spinning disks handle that scattered-small-read pattern worst.
# This is now handled automatically by the storage subsystem's
# postgres-vda service: the postgres clusters live on the array at rest
# (so the database travels with the disks, UNVR-style) but are served from
# a working copy on vda — the OS disk, a qcow2 on the host's NVMe — while
# the VM runs, and synced back to the array at every clean shutdown. There
# is no separate-disk migration step to run, and nothing here to configure.
# See /usr/local/sbin/postgres-vda.sh for the mechanism.
#
# Usage:
#   ./mount-storage.sh status
#   ./mount-storage.sh import
#
# Run as root inside the VM.
###############################################################################

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

# Parse arguments. Positional args land in POSITIONAL[]; --help prints the
# header block.
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            sed -n '2,50p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

ACTION="${POSITIONAL[0]:-status}"

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
    # pg_lsclusters shows where each postgres cluster's data lives. The
    # 'access' and 'protect' clusters' data_directory is /srv/postgresql,
    # which the postgres-vda service overlays with a vda working copy
    # while the VM runs (NVMe speed) and syncs back to the array at clean
    # shutdown. 'main' lives on /data which is the VM rootfs.
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
# Execute
###############################################################################

case "$ACTION" in
    status) status ;;
    import) import ;;
    *)
        echo "Usage: $0 <status|import>"
        exit 1
        ;;
esac
