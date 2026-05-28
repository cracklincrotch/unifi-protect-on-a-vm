#!/bin/bash
###############################################################################
# install-shims.sh
#
# Install the hardware-spoofing shims that let UNVR user-space software run
# on a VM. Run as root, inside the Protect VM.
#
# WHY THIS IS A SEPARATE SCRIPT
#
# The UNVR firmware ships ubnt-tools and uled-ctrl as real binaries that
# probe physical NVR hardware (board EEPROM, disk bays, LEDs), and smartctl
# for disk health. On a VM there is nothing to probe, so this script
# replaces them with fakes/wrappers that return sane values.
#
# The catch: update-unifi.sh --sync-os repacks and reinstalls EVERY
# Ubiquiti package straight from the firmware squashfs — which puts the
# real binaries back and breaks the VM. So both the initial install and
# every sync-os must (re)apply these shims. Keeping them in one idempotent
# script means there is exactly one definition for both callers to use.
#
# NOTE: ustorage is NOT handled here — the dynamic ustorage replacement is
# owned by install-storage.sh. This script must never write /usr/bin/
# ustorage or it would clobber that on a re-run.
#
# Idempotent: safe to run any number of times.
#
# Environment:
#   STORAGE_DISK    - block device for /volume1 (default /dev/sda). Only
#                     used to seed /etc/default/storage_disk on first run.
#   DEVICE          - UNVR / UNVR_PRO / ENVR (default UNVR). Only used to
#                     seed /etc/default/device on first run.
###############################################################################
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "install-shims.sh: must run as root" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_TREE="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo "")"

STORAGE_DISK="${STORAGE_DISK:-/dev/sda}"
DEVICE="${DEVICE:-UNVR}"

echo ">>> Installing hardware-spoofing shims..."

# --- /etc/default/storage_disk + /etc/default/device ---
# ubnt-tools reads /etc/default/device for the board identity. They are
# our own config files (no Ubiquiti package owns them), so a sync-os does
# not touch them — seed them on first run, preserve after.
if [ ! -f /etc/default/storage_disk ]; then
    # NOTE: no #!/bin/bash line — this is sourced as a config file.
    cat > /etc/default/storage_disk << STORAGEOF
STORAGE_DISK=${STORAGE_DISK}
STORAGEOF
fi
if [ ! -f /etc/default/device ]; then
    echo "$DEVICE" > /etc/default/device
fi

# --- /sbin/ubnt-tools (fake board identity) ---
# ubnt-tools comes from UNVR firmware, not a real binary. Back up the
# genuine one once, the first time we see it; later sync-os runs just
# overwrite our fake with the fresh fake.
if [ -f /sbin/ubnt-tools ] && [ ! -f /sbin/ubnt-tools.orig ]; then
    mv /sbin/ubnt-tools /sbin/ubnt-tools.orig
fi
cat > /sbin/ubnt-tools << 'UBNTEOF'
#!/bin/bash

if [ "${1:-}" = 'id' ]; then
    if [ ! -f /data/uuid.txt ]; then
        cat /proc/sys/kernel/random/uuid > /data/uuid.txt
    fi
    uuid=$(cat /data/uuid.txt)
    serial=$(cat /sys/class/net/$(ip route get 8.8.8.8 | grep -Po '(?<=(dev ))(\S+)')/address | sed 's/://g')

    if [ -f /etc/default/device ]; then
        DEVICE="$(tr -d '\n' < /etc/default/device)"
    fi
    case "${DEVICE:-UNVR}" in
        'UNVR_PRO')
            echo "board.sysid=0xea20"
            echo "board.name=UniFi Network Video Recorder Pro"
            echo "board.shortname=UNVRPRO";;
        'MAC_OS')
            echo "board.sysid=0xffff"
            echo "board.name=UniFi Network Video Recorder"
            echo "board.shortname=UNVR";;
        'ENVR')
            echo "board.sysid=0xea3f"
            echo "board.name=UniFi Enterprise Network Video Recorder"
            echo "board.shortname=ENVR";;
        *)
            echo "board.sysid=0xea16"
            echo "board.name=UniFi Network Video Recorder"
            echo "board.shortname=UNVR";;
    esac

    echo "board.subtype="
    echo "board.reboot=30"
    echo "board.upgrade=310"
    echo "board.cpu.id=00000000-00000000"
    echo "board.uuid=${uuid}"
    echo "board.bom=1"
    echo "board.hwrev=1"
    echo "board.serialno=${serial}"
    echo "board.qrid=sTpBUR"
fi
UBNTEOF
chmod +x /sbin/ubnt-tools

# NOTE: /usr/bin/ustorage is deliberately NOT installed here. The dynamic
# ustorage replacement (storage/rootfs/usr/bin/ustorage — it reads the
# real disks and md array) is owned solely by install-storage.sh.
# Installing a static fake here as well would clobber the real one on
# every re-run of this script, leaving Protect to believe the 32 GB OS
# disk is the recording volume.

# --- /usr/bin/uled-ctrl (dummy LED controller) ---
touch /usr/bin/uled-ctrl
chmod +x /usr/bin/uled-ctrl

# --- /usr/sbin/smartctl (proxy wrapper) ---
# The wrapper forwards SMART queries over the host<->guest control channel
# and normalizes the host's reply into a per-disk ATA report. It works for
# both raw-passthrough and qcow2-image disks, and reports each disk
# distinctly — unlike the old single-disk static fake it replaces. If the
# channel is down it falls back to the real binary. See the wrapper at
# vm/wrappers/rootfs/usr/sbin/smartctl for the full behaviour.
echo "    installing smartmontools + smartctl proxy wrapper"
apt-get --no-install-recommends -y install smartmontools

# smartd probes real disks on a timer and fails on a VM — not wanted.
systemctl disable --now smartd 2>/dev/null || true

# Stash the genuine smartmontools binary as smartctl.real so the wrapper
# can fall back to it. A naive "mv smartctl -> smartctl.real" misfires if
# /usr/sbin/smartctl is currently a script — the old static fake, or this
# wrapper from a prior run — capturing the script as the "real" binary.
# Detect that, and reinstall smartmontools to restore the genuine binary.
is_script() { head -c2 "$1" 2>/dev/null | grep -q '#!'; }

if [ -f /usr/sbin/smartctl.real ] && ! is_script /usr/sbin/smartctl.real; then
    :   # a genuine real binary is already stashed — leave it
else
    rm -f /usr/sbin/smartctl.real
    if [ ! -e /usr/sbin/smartctl ] || is_script /usr/sbin/smartctl; then
        # /usr/sbin/smartctl is missing or a script — restore the real
        # binary from the package before stashing it.
        apt-get install --reinstall --no-install-recommends -y smartmontools
    fi
    mv /usr/sbin/smartctl /usr/sbin/smartctl.real
fi

if [ -n "$VM_TREE" ] && \
   [ -f "$VM_TREE/wrappers/rootfs/usr/sbin/smartctl" ]; then
    install -m 0755 "$VM_TREE/wrappers/rootfs/usr/sbin/smartctl" \
        /usr/sbin/smartctl
    install -m 0644 "$VM_TREE/wrappers/smartctl-proxy.conf.example" \
        /etc/default/smartctl-proxy
    echo "    installed smartctl proxy wrapper"
else
    echo "    WARNING: smartctl wrapper not found in the vm/ tree —"
    echo "             restoring the real binary; proxy NOT installed"
    [ -f /usr/sbin/smartctl.real ] && \
        cp -a /usr/sbin/smartctl.real /usr/sbin/smartctl
fi

echo ">>> Hardware-spoofing shims installed."
