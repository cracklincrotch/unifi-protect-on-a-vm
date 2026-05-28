#!/bin/bash
###############################################################################
# uninstall.sh
#
# Helper for the reverse-migration workflow: moving from this VM-based
# Protect setup back to a real UNVR, an ENVR, or some other UniFi
# controller hardware.
#
# THE FULL REVERSE-MIGRATION WORKFLOW
#
# Just like the forward migration was backup-first, the reverse is too.
# The disks alone don't carry the right state — the target hardware has
# its own postgres clusters and needs the data restored via the web UI,
# not by direct disk import.
#
#   1. Back up Protect and Access via the VM's web UI. Download both
#      backup files.
#   2. Run this script with `migrate`. It moves postgres back from a
#      dedicated SSD (if applicable) to the standard /srv/postgresql
#      location on the spinning RAID, so the disks have a complete
#      UNVR-style layout.
#   3. Shut the VM down cleanly: systemctl poweroff
#   4. Pull the disks from the DAS.
#   5. Install them in the target hardware (real UNVR, ENVR, etc.).
#   6. Power on the target hardware.
#   7. Restore the Protect and Access backups via the target's web UI.
#   8. Cameras re-adopt automatically using the restored identity.
#
# WHAT THIS SCRIPT DOES
#
# Only step 2 of the above. If postgres was migrated to a dedicated SSD
# via mount-storage.sh postgres-migrate, this script reverses it — moves
# the data back to /srv/postgresql on the RAID, removes the SSD mount,
# updates fstab. It leaves the VM functional but prepped for export.
#
# WHAT THIS SCRIPT DOES NOT DO
#
# - It does NOT take the Protect/Access backups. You do that via the
#   VM's web UI before running this script.
# - It does NOT uninstall the Ubiquiti software. The VM stays functional;
#   you can keep running it.
# - It does NOT remove the host-side launchd daemon. Use
#   install-launchd.sh uninstall on the host for that.
# - It does NOT delete recordings or any actual Protect/Access data.
#
# Usage:
#   ./uninstall.sh status        # Show what would change
#   ./uninstall.sh migrate       # Move postgres back to the RAID
#   ./uninstall.sh migrate --force   # Skip confirmation prompts
#
# Run as root inside the VM.
###############################################################################

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

# Parse flags
FORCE=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --help|-h)
            sed -n '2,50p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

ACTION="${POSITIONAL[0]:-status}"

###############################################################################
# Helpers
###############################################################################

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

confirm_strict() {
    local prompt="$1"
    if [ "$FORCE" -eq 1 ]; then
        echo "$prompt [forced — skipping confirmation]"
        return 0
    fi
    echo ""
    echo "$prompt"
    echo "This will stop services and move data. The VM will be unavailable"
    echo "for a few minutes while it runs."
    echo "Type 'YES' (in all capitals) to proceed, or anything else to abort:"
    read -r response
    if [ "$response" = "YES" ]; then
        return 0
    fi
    echo "Aborted."
    return 1
}

# Strongly recommend a host-side snapshot before destructive operations.
# Snapshots are instant copy-on-write checkpoints of the VM disks — the
# fast rollback path if something goes wrong. The VM itself can't take
# the snapshot, so we just remind the user.
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

This operation moves database data between disks and modifies fstab. A
snapshot of the VM disks gives you a one-command rollback path if
something goes wrong. Snapshots are fast (the VM pauses for a few
seconds), take no extra space until data changes, and can be deleted
later.

To take one — no VM shutdown required:
  1. Press Ctrl+C now to abort this script
  2. On the host:  ./snapshot.sh create-auto pre-uninstall
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
# Detect whether postgres is on a separate disk and show what the migrate
# action would do.
###############################################################################

# Check whether /srv/postgresql is mounted from a separate disk (i.e., the
# postgres-migrate has been performed). Returns 0 if so, 1 if postgres is
# already on the RAID.
postgres_on_separate_disk() {
    # If /srv/postgresql is its own mount point, it's on a separate disk.
    # We can tell because mountpoint -q returns 0 in that case.
    mountpoint -q /srv/postgresql 2>/dev/null
}

# Get the device that backs /srv/postgresql if it's its own mount.
get_postgres_device() {
    findmnt -n -o SOURCE /srv/postgresql 2>/dev/null || true
}

status() {
    echo "=============================================="
    echo "Uninstall / migrate-out status"
    echo "=============================================="
    echo ""

    if postgres_on_separate_disk; then
        local pg_device
        pg_device=$(get_postgres_device)
        echo ">>> Postgres is on a separate disk: $pg_device"
        echo ""
        echo "    Running 'uninstall.sh migrate' will:"
        echo "      - Stop all UniFi services"
        echo "      - Copy postgres data from $pg_device back to the RAID"
        echo "      - Update fstab to remove the separate postgres mount"
        echo "      - Restart services"
        echo "      - Leave $pg_device unmounted (you can remove it after)"
    else
        echo ">>> Postgres is already on the RAID at /srv/postgresql."
        echo "    Nothing for the migrate action to do."
    fi

    echo ""
    echo ">>> Mount points relevant to the data:"
    mount | grep -E "(/volume1|/srv/postgresql|/srv)" || echo "    (none)"

    echo ""
    echo ">>> /etc/fstab (data lines):"
    grep -v "^#" /etc/fstab | grep -v "^$" | grep -E "(volume1|postgresql|pgdata)" || \
        echo "    (none)"

    echo ""
    echo ">>> /srv layout:"
    ls -la /srv 2>/dev/null

    echo ""
    echo ">>> Data sizes on the RAID:"
    if mountpoint -q /volume1; then
        du -sh /volume1/.srv/* 2>/dev/null | head -20
    else
        echo "    /volume1 is not mounted!"
    fi
}

###############################################################################
# Action: MIGRATE
#
# Move postgres back to /srv/postgresql on the RAID.
###############################################################################

migrate() {
    echo "=============================================="
    echo "Migrate postgres back to the RAID"
    echo "=============================================="

    if ! postgres_on_separate_disk; then
        echo ""
        echo "Postgres is already on the RAID. Nothing to do."
        echo ""
        echo "If you want to verify the data is in the right place, run:"
        echo "  ./uninstall.sh status"
        return 0
    fi

    local pg_device
    pg_device=$(get_postgres_device)

    echo ""
    echo "Current state:"
    echo "  Postgres data lives on: $pg_device"
    echo "  Will be moved to:       /volume1/.srv/postgresql (on the RAID)"
    echo ""
    echo "Sizes:"
    df -h "$pg_device" 2>/dev/null | tail -1
    df -h /volume1 2>/dev/null | tail -1

    recommend_snapshot "migrate postgres from $pg_device back to /srv/postgresql on the RAID"

    confirm_strict "About to migrate postgres back to the RAID." || return 1

    echo ""
    echo ">>> Stopping all UniFi services..."
    systemctl stop unifi-protect unifi-access ai-feature-console ds unifi-core ulp-go uid-agent 2>/dev/null || true
    systemctl stop postgresql.service 2>/dev/null || true

    # Mask services during migration to prevent restart loops.
    for svc in unifi-protect unifi-access ds ai-feature-console postgresql; do
        systemctl mask "${svc}.service" 2>/dev/null || true
    done
    sleep 3

    pkill -9 postgres 2>/dev/null || true
    sleep 2

    if pgrep postgres >/dev/null; then
        echo "ERROR: postgres still running after kill. Aborting." >&2
        # Try to restore services so we don't leave the system stuck.
        for svc in unifi-protect unifi-access ds ai-feature-console postgresql; do
            systemctl unmask "${svc}.service" 2>/dev/null || true
        done
        return 1
    fi

    echo ""
    echo ">>> Copying data from $pg_device to a temporary location..."
    # Strategy: copy data off the SSD to a temp dir on the RAID, then
    # unmount the SSD, then move temp into place.
    local tmpdir="/volume1/.srv/postgresql.migrating.$(date +%s)"
    mkdir -p "$tmpdir"
    rsync -aHAX --info=progress2 /srv/postgresql/ "$tmpdir/"

    echo ""
    echo ">>> Unmounting $pg_device from /srv/postgresql..."
    umount /srv/postgresql

    echo ""
    echo ">>> Moving copied data into /srv/postgresql..."
    # /srv/postgresql is now an empty directory (or doesn't exist). The
    # rsync target was a sibling directory under .srv/ — move its contents.
    # We need to handle the case where /srv/postgresql exists as a directory.
    if [ -d /srv/postgresql ]; then
        rmdir /srv/postgresql 2>/dev/null || true
    fi
    # /srv is a symlink to /volume1/.srv, so /srv/postgresql resolves to
    # /volume1/.srv/postgresql. mv the temp directory into that name.
    mv "$tmpdir" /volume1/.srv/postgresql
    chown postgres:postgres /volume1/.srv/postgresql

    echo ""
    echo ">>> Removing pgdata entry from /etc/fstab..."
    # Remove any LABEL=pgdata or UUID-of-the-old-postgres-disk lines.
    sed -i '/pgdata/d' /etc/fstab
    sed -i '/\/srv\/postgresql/d' /etc/fstab

    echo ""
    echo ">>> Unmasking and starting services..."
    for svc in unifi-protect unifi-access ds ai-feature-console postgresql; do
        systemctl unmask "${svc}.service" 2>/dev/null || true
    done
    systemctl daemon-reload
    systemctl start postgresql.service
    sleep 5
    systemctl start unifi-core ds ai-feature-console ulp-go uid-agent unifi-access unifi-protect

    echo ""
    echo "=============================================="
    echo "Postgres migration complete."
    echo "=============================================="
    echo ""
    echo "Postgres now lives on the RAID at /srv/postgresql."
    echo ""
    echo "The disk that previously held postgres ($pg_device) is now unmounted"
    echo "and can be detached. It still contains the old postgres data — you"
    echo "may want to:"
    echo "  - Keep it as a backup until you've confirmed the migration worked"
    echo "  - Wipe it with: wipefs -a $pg_device  (only after you're satisfied)"
    echo ""
    echo "TO COMPLETE THE REVERSE MIGRATION TO REAL HARDWARE:"
    echo ""
    echo "  1. (Already done if you got here) Back up Protect and Access via"
    echo "     the VM web UI. Download both backup files."
    echo "  2. Verify the VM still works correctly with postgres on the RAID."
    echo "  3. Shut down the VM cleanly: systemctl poweroff"
    echo "  4. Pull the disks from the DAS."
    echo "  5. Install the disks in the target hardware (UNVR, ENVR, etc.)."
    echo "  6. Power on the target. Wait for it to come up to its setup state."
    echo "  7. Restore the Protect and Access backups via the target's web UI."
    echo "  8. Cameras will re-adopt to the target controller within a few"
    echo "     minutes, using the identity from the restored backup."
    echo ""
    echo "If you haven't already taken the Protect and Access backups, STOP"
    echo "and do that now via the VM web UI before powering down."
    echo ""
    echo "No guarantees the move to different hardware works perfectly."
    echo "Hardware differences and firmware versions can still cause issues."
}

###############################################################################
# Execute
###############################################################################

case "$ACTION" in
    status)  status ;;
    migrate) migrate ;;
    *)
        echo "Usage: $0 [--force] <status|migrate>"
        echo ""
        echo "  status   Show what migrate would change"
        echo "  migrate  Move postgres back to the spinning RAID"
        echo ""
        echo "Flags:"
        echo "  --force, -f   Skip confirmation prompts (use with care)"
        exit 1
        ;;
esac
