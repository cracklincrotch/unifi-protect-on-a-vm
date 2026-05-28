#!/bin/bash
###############################################################################
# smartctl-host-helper.sh
#
# Host (macOS) side of the optional smartctl proxy.
#
# THE PROBLEM
#
# Inside the Protect VM, disks are virtio-scsi devices. virtio-scsi has no
# real SMART data — so Protect's UI can never show genuine disk health,
# bad-sector counts, temperature, or failure warnings for the disks that
# actually hold your recordings. Those disks are USB-attached to the Mac.
#
# THE PROXY
#
# The VM-side wrapper (/usr/sbin/smartctl) resolves the disk it was asked
# about to its serial number and sends it over the host<->guest control
# channel. control-host-helper.sh — the channel dispatcher — invokes this
# script for the `smartctl` verb. This script looks the serial up in the
# disk map and runs the real smartctl against the right host device:
#
#   - a raw-passthrough disk maps straight to its /dev/diskN;
#   - a qcow2 image maps to the physical disk the image file lives on
#     (resolved via df + diskutil), so an image-backed VM disk reports the
#     health of the real medium underneath it.
#
# The Mac CAN read SMART over USB, provided the kasbert OS-X-SAT-SMART
# kext (or DriveDx, which bundles it) is installed.
#
# HOW IT IS INVOKED
#
# By control-host-helper.sh, with the request as positional arguments:
#
#   smartctl-host-helper.sh <serial> <flag> <flag> ...
#
# (Earlier versions were an SSH forced command; the channel is now
# virtio-serial — see control-host-helper.sh. You can still run this
# script directly with the same arguments for manual testing.)
#
# SECURITY
#
#   - The control channel only ever calls this script for the `smartctl`
#     verb — the dispatcher has no code path to run anything else.
#   - The serial and every forwarded flag are validated against a strict
#     character set, and state-changing smartctl flags (self-tests,
#     --set, SMART enable/disable) are rejected outright. This script only
#     ever performs read-only SMART queries.
#   - The target device is looked up from the serial map written by
#     start-protect-vm.sh — the caller cannot specify an arbitrary device.
#   - smartctl runs unprivileged: on macOS it reads SMART through IOKit,
#     which needs no root, so no sudo and no sudoers rule are involved.
#
# SETUP
#
# See the README "smartctl proxy" section for the full walkthrough
# (installing this script and the sudoers rule).
###############################################################################

# No `set -u`: macOS ships bash 3.2, where expanding an empty array under
# `set -u` is an error. We rely on explicit checks instead.
set -eo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

# Serial-to-device map written by start-protect-vm.sh on every VM start.
# This MUST match the DISK_MAP value in protect-on-mac.conf. The default
# below matches the default there ($VM_DATA_DIR/disk-serial.map with the
# default VM_DATA_DIR of $HOME/unifi-protect/vm-data).
DISK_MAP="${DISK_MAP:-$HOME/unifi-protect/vm-data/disk-serial.map}"

# Path to the real smartctl on the host. Homebrew's default on Apple
# Silicon. Override via the SMARTCTL env var if yours differs.
SMARTCTL="${SMARTCTL:-/opt/homebrew/bin/smartctl}"

# Upper bounds — a sane request is well under these. Anything larger is
# treated as malformed input.
MAX_TOKENS=24
MAX_SERIAL_LEN=64

###############################################################################
# Input
###############################################################################

# The request arrives as positional arguments: "<serial> [flags...]".
args=("$@")

if [ "${#args[@]}" -lt 1 ]; then
    echo "smartctl-host-helper: no input (expected '<serial> [flags...]')" >&2
    exit 64
fi
if [ "${#args[@]}" -gt "$MAX_TOKENS" ]; then
    echo "smartctl-host-helper: too many arguments" >&2
    exit 64
fi

serial="${args[0]}"
flags=("${args[@]:1}")

###############################################################################
# Validate
###############################################################################

# Serial: letters, digits, and . _ - only. Anything else is malformed or
# an injection attempt.
if [ -z "$serial" ] || [ "${#serial}" -gt "$MAX_SERIAL_LEN" ]; then
    echo "smartctl-host-helper: bad serial" >&2
    exit 64
fi
case "$serial" in
    *[!A-Za-z0-9._-]*)
        echo "smartctl-host-helper: bad serial characters" >&2
        exit 64 ;;
esac

# Flags: strict character set (no shell metacharacters, no spaces), and
# state-changing smartctl operations are refused. This script is
# read-only by policy.
for f in "${flags[@]}"; do
    case "$f" in
        *[!A-Za-z0-9=,._-]*)
            echo "smartctl-host-helper: bad flag characters: $f" >&2
            exit 64 ;;
    esac
    case "$f" in
        -t|--test|--test=*|-s|--smart|--smart=*|-S|--saveauto|--saveauto=*|\
        -o|--offlineauto|--offlineauto=*|--set|--set=*|--set-*)
            echo "smartctl-host-helper: refusing state-changing flag: $f" >&2
            exit 64 ;;
    esac
done

###############################################################################
# Resolve the serial to a device
###############################################################################

if [ ! -r "$DISK_MAP" ]; then
    echo "smartctl-host-helper: disk map not found at $DISK_MAP" >&2
    echo "  (start-protect-vm.sh writes it when the VM starts)" >&2
    exit 69
fi

# Map line for this serial: "serial<TAB>kind<TAB>target".
map_line="$(awk -F'\t' -v s="$serial" '$1 == s { print; exit }' "$DISK_MAP")"
if [ -z "$map_line" ]; then
    echo "smartctl-host-helper: serial '$serial' not in $DISK_MAP" >&2
    exit 69
fi
kind="$(printf '%s' "$map_line" | cut -f2)"
target="$(printf '%s' "$map_line" | cut -f3)"

# Tolerate an older 2-column map ("serial<TAB>/dev/diskN"): if column 2
# is a device path, treat the line as a passthrough disk.
case "$kind" in
    /dev/*) target="$kind"; kind="disk" ;;
esac

# Resolve a qcow2 image path to the physical disk it physically lives on.
# An APFS volume sits on a synthesized container whose "APFS Physical
# Store" is the real hardware; a non-APFS volume's "Part of Whole" is.
resolve_image_to_disk() {
    local img="$1" vol store whole
    if [ ! -e "$img" ]; then
        echo "smartctl-host-helper: image not found: $img" >&2
        return 1
    fi
    vol="$(df "$img" 2>/dev/null | awk 'NR==2 {print $1}')"
    if [ -z "$vol" ]; then
        echo "smartctl-host-helper: cannot resolve a volume for $img" >&2
        return 1
    fi
    store="$(diskutil info "$vol" 2>/dev/null \
             | awk -F':' '/APFS Physical Store/ {print $2; exit}' \
             | tr -d '[:space:]')"
    if [ -z "$store" ]; then
        store="$(diskutil info "$vol" 2>/dev/null \
                 | awk -F':' '/Part of Whole/ {print $2; exit}' \
                 | tr -d '[:space:]')"
    fi
    if [ -z "$store" ]; then
        echo "smartctl-host-helper: no physical disk for $img" >&2
        return 1
    fi
    whole="${store%%s[0-9]*}"          # disk0s2 -> disk0
    printf '/dev/%s\n' "$whole"
}

case "$kind" in
    disk)
        dev="$target" ;;
    image)
        dev="$(resolve_image_to_disk "$target")" || exit 69 ;;
    *)
        echo "smartctl-host-helper: unknown disk kind '$kind' for '$serial'" >&2
        exit 69 ;;
esac

# Defense in depth: confirm it looks like a macOS whole-disk node before
# handing it to sudo.
case "$dev" in
    /dev/disk[0-9]*) ;;
    *)
        echo "smartctl-host-helper: unexpected device '$dev'" >&2
        exit 69 ;;
esac

###############################################################################
# Run the real smartctl
###############################################################################

if [ ! -x "$SMARTCTL" ]; then
    echo "smartctl-host-helper: smartctl not found at $SMARTCTL" >&2
    echo "  Install it on the host: brew install smartmontools" >&2
    exit 69
fi

# smartctl reads SMART through IOKit on macOS — no root required, so no
# sudo here.
#
# smartctl's exit status is a bitmask: bit 0 = command-line error,
# bit 1 = device open failed. Either means the proxy itself failed and
# the VM wrapper should fall back to local data, so we report an error.
# Higher bits mean smartctl reached the disk and the disk reported
# something (bad health, prefail attributes, etc.) — that output is
# exactly what we want Protect to see, so we pass it through and exit 0.
if out="$("$SMARTCTL" "${flags[@]}" "$dev" 2>&1)"; then
    status=0
else
    status=$?
fi

if [ $((status & 3)) -ne 0 ]; then
    echo "smartctl-host-helper: smartctl could not read $dev (exit $status)" >&2
    printf '%s\n' "$out" >&2
    exit 70
fi

printf '%s\n' "$out"
exit 0
