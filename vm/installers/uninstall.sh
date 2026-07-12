#!/bin/bash
###############################################################################
# uninstall.sh
#
# Helper for the reverse-migration workflow: moving from this VM-based
# Protect setup back to a real UNVR, an ENVR, or some other UniFi
# controller hardware. This script only reports state and prints the
# checklist — the data movement is handled automatically (see below).
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
#   2. Shut the VM down cleanly: systemctl poweroff
#   3. Pull the disks from the DAS.
#   4. Install them in the target hardware (real UNVR, ENVR, etc.).
#   5. Power on the target hardware.
#   6. Restore the Protect and Access backups via the target's web UI.
#   7. Cameras re-adopt automatically using the restored identity.
#
# WHY THERE IS NO LONGER A "migrate" STEP
#
# Older versions of this project kept postgres on a dedicated SSD and you
# had to run `uninstall.sh migrate` to move it back onto the RAID before
# export. That mechanism (and its shutdown-time sync back to the array) is
# gone. Protect keeps its postgres cluster on the built-in SSD (vda) via
# its own /ssd1 detection — genuine UNVR-with-SSD behaviour — and the
# database is captured in the whole-system config backup, not on the array.
# The array carries the recordings, which travel with the disks. So the
# recovery set is simply: the disks (recordings) plus the config backup you
# restore on the target via its web UI — the standard UNVR path. There is
# nothing to migrate; just take your web-UI backups and `poweroff`.
#
# unifi-core writes those small config backups (protect + access + users,
# a few MB — NOT recordings) to /data/unifi-core/backups on its own
# schedule, and the protect-backup-to-array.timer mirrors them onto the
# array at /volume1/.srv/protect-config-backups (newest 30 kept), so a copy
# also travels with the disks.
#
# WHAT THIS SCRIPT DOES NOT DO
#
# - It does NOT take the Protect/Access backups. You do that via the
#   VM's web UI before powering down.
# - It does NOT uninstall the Ubiquiti software. The VM stays functional.
# - It does NOT remove the host-side launchd daemon. Use
#   install-launchd.sh uninstall on the host for that.
# - It does NOT delete recordings or any actual Protect/Access data.
#
# Usage:
#   ./uninstall.sh status        # Show export readiness and the checklist
#
# Run as root inside the VM.
###############################################################################

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

ACTION="${1:-status}"

# Print the reverse-migration checklist.
print_checklist() {
    cat <<'EOF'

TO COMPLETE THE REVERSE MIGRATION TO REAL HARDWARE:

  1. Back up Protect and Access via the VM web UI. Download both files.
  2. Verify the VM is working correctly.
  3. Shut the VM down cleanly: systemctl poweroff
     (recordings are already on the disks; the backup carries the rest.)
  4. Pull the disks from the DAS.
  5. Install the disks in the target hardware (UNVR, ENVR, etc.).
  6. Power on the target. Wait for it to reach its setup state.
  7. Restore the Protect and Access backups via the target's web UI.
  8. Cameras re-adopt to the target controller within a few minutes,
     using the identity from the restored backup.

If you haven't already taken the Protect and Access backups, STOP and do
that now via the VM web UI before powering down.

No guarantees the move to different hardware works perfectly. Hardware
differences and firmware versions can still cause issues.
EOF
}

status() {
    echo "=============================================="
    echo "Reverse-migration / export readiness"
    echo "=============================================="
    echo ""

    # Is the recording array mounted?
    if mountpoint -q /volume1 2>/dev/null; then
        echo ">>> Recording array: mounted at /volume1"
    else
        echo ">>> Recording array: NOT mounted at /volume1 (!)"
    fi

    # Postgres runs on the built-in SSD (vda) via Protect's own /ssd1
    # detection; config backups are mirrored to the array on a timer.
    if [ -e /ssd1 ]; then
        echo ">>> Postgres: on the SSD (/data via /ssd1) — not on the array."
    else
        echo ">>> Postgres: /ssd1 marker absent (Protect may place the DB on"
        echo "    the array; the config backup below is the export path anyway)."
    fi
    if systemctl is-active --quiet protect-backup-to-array.timer 2>/dev/null; then
        echo ">>> Config-backup mirror: active — backups copied to the array"
        echo "    at /volume1/.srv/protect-config-backups (newest 30 kept)."
    else
        echo ">>> Config-backup mirror: protect-backup-to-array.timer not active"
        echo "    (take/verify a web-UI backup before export)."
    fi

    echo ""
    echo ">>> Config backups mirrored on the array:"
    ls -la /volume1/.srv/protect-config-backups 2>/dev/null | head -5 || \
        echo "    /volume1/.srv/protect-config-backups not present (none yet)"

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
    echo ">>> Data sizes on the array:"
    if mountpoint -q /volume1 2>/dev/null; then
        du -sh /volume1/.srv/* 2>/dev/null | head -20
    else
        echo "    /volume1 is not mounted!"
    fi

    print_checklist
}

case "$ACTION" in
    status) status ;;
    migrate)
        # Backward-compatibility note for anyone following older docs.
        echo "The 'migrate' step is no longer needed."
        echo ""
        echo "Protect keeps its postgres cluster on the built-in SSD (vda) via"
        echo "its own /ssd1 detection, and the database is captured in the config"
        echo "backup, so there is nothing to migrate onto the array. The disks"
        echo "carry the recordings; the config backup carries the rest."
        echo "Just take your web-UI backups and 'systemctl poweroff'."
        echo ""
        echo "Run './uninstall.sh status' to see export readiness and the checklist."
        ;;
    *)
        echo "Usage: $0 <status>"
        echo ""
        echo "  status   Show export readiness and the reverse-migration checklist"
        exit 1
        ;;
esac
