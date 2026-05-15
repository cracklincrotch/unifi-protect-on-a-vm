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
# The VM-side wrapper (/usr/sbin/smartctl, installed by
# install-protect-baremetal.sh with SMARTCTL_PROXY=1) resolves the disk it
# was asked about to its serial number, then SSHes to this host. This
# script is the forced command on the receiving end: it translates the
# serial back into the /dev/diskN the disk currently maps to and runs the
# real smartctl against it. The Mac CAN read SMART over USB, provided the
# kasbert OS-X-SAT-SMART kext (or DriveDx, which bundles it) is installed.
#
# HOW IT IS INVOKED
#
# Via SSH with a forced command. The VM's authorized_keys entry on this
# host looks like:
#
#   command="/usr/local/bin/smartctl-host-helper.sh",no-pty,\
#   no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA...
#
# The VM passes "<serial> <flag> <flag> ..." which SSH delivers here in
# SSH_ORIGINAL_COMMAND. For manual testing you can also run this script
# directly with the same arguments on the command line.
#
# SECURITY
#
#   - The forced command means a holder of the VM's key can ONLY run this
#     script, nothing else.
#   - The serial and every forwarded flag are validated against a strict
#     character set, and state-changing smartctl flags (self-tests,
#     --set, SMART enable/disable) are rejected outright. This script only
#     ever performs read-only SMART queries.
#   - The target device is looked up from the serial map written by
#     start-protect-vm.sh — the caller cannot specify an arbitrary device.
#   - smartctl is run via `sudo -n`; see the sudoers rule in the README.
#
# SETUP
#
# See the README "smartctl proxy" section for the full walkthrough
# (installing this script, the sudoers rule, enabling Remote Login, and
# adding the VM's public key).
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

# Input arrives via SSH_ORIGINAL_COMMAND under the forced command. When
# run directly (manual testing) fall back to positional arguments.
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    read -r -a args <<< "$SSH_ORIGINAL_COMMAND"
else
    args=("$@")
fi

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

dev="$(awk -F'\t' -v s="$serial" '$1 == s { print $2; exit }' "$DISK_MAP")"

if [ -z "$dev" ]; then
    echo "smartctl-host-helper: serial '$serial' not in $DISK_MAP" >&2
    exit 69
fi

# Defense in depth: the device comes from our own map, but confirm it
# looks like a macOS whole-disk node before handing it to sudo.
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

# Raw device access on macOS requires root, hence sudo. The sudoers rule
# (see README) grants passwordless access to exactly this binary.
#
# smartctl's exit status is a bitmask: bit 0 = command-line error,
# bit 1 = device open failed. Either means the proxy itself failed and
# the VM wrapper should fall back to local data, so we report an error.
# Higher bits mean smartctl reached the disk and the disk reported
# something (bad health, prefail attributes, etc.) — that output is
# exactly what we want Protect to see, so we pass it through and exit 0.
if out="$(sudo -n "$SMARTCTL" "${flags[@]}" "$dev" 2>&1)"; then
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
