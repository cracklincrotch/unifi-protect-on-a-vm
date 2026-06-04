#!/bin/bash
###############################################################################
# start-protect-vm.sh
#
# Start the Protect VM on macOS via QEMU with stable hardware references.
#
# THE CORE PROBLEM THIS SCRIPT SOLVES
#
# macOS assigns /dev/diskN numbers in connection order, not by identity.
# Plug your DAS in after a reboot and disk5 might become disk7. Disconnect
# and reconnect the dock and your ethernet adapter's "en5" might become
# "en4". If the QEMU command line is hardcoded to /dev/disk5 and en5,
# those changes break the VM's storage and network.
#
# This script resolves hardware by stable identifiers — disks by ATA
# serial number, the ethernet by MAC address — and constructs the QEMU
# command line fresh each time. The VM sees the same disks and network
# regardless of how macOS happens to enumerate them this boot.
#
# OTHER THINGS THIS SCRIPT DOES
#
# - Maps physical ATA serials to QEMU device serials. Inside the VM,
#   `lsblk -o NAME,SERIAL` shows the real ATA serials of the underlying
#   disks. This helps when correlating SMART data, mdadm output, etc.
# - Optionally attaches extra qcow2 disk images listed in STORAGE_IMAGES.
# - Sanity-checks that EFI firmware, EFI vars, and the VM disk all exist
#   before launching. QEMU errors are cryptic if you mistype a path.
# - Uses Apple's HVF accelerator (accel=hvf) which is essentially
#   pass-through CPU virtualization on M-series Macs.
#
# REQUIRED HOST SETUP
#
#   brew install qemu wget jq
#
#   sudo visudo -f /etc/sudoers.d/qemu-vm
#   # Add this line (replace `donnie` with your username):
#   #   donnie ALL=(root) NOPASSWD: /opt/homebrew/bin/qemu-system-aarch64
#
# Without the sudoers entry, every VM start requires the admin password.
# We need sudo because raw disk access (/dev/disk*) requires root on
# macOS — there's no way to give a regular user permission to read/write
# block devices.
#
# IDENTIFYING YOUR HARDWARE
#
# For each disk in the DAS:
#   smartctl -i /dev/diskN | grep "Serial Number"
#
# For your ethernet adapter's MAC:
#   networksetup -listallhardwareports
# Look for the adapter you want the VM to bridge through (built-in, USB,
# Thunderbolt, etc.) and copy its "Ethernet Address" value.
#
###############################################################################

# Exit on errors but don't enable -u (unset variable checking) because the
# resolver functions return empty strings when nothing matches, which is a
# normal case we handle explicitly.
set -e

###############################################################################
# CONFIGURATION
###############################################################################
#
# Each VM owns its config: protect-on-mac.conf lives in the VM's data
# directory (VM_DATA_DIR), alongside its disks and EFI vars. stand-up.sh
# creates it there. The conf is located in this order:
#   1. $PROTECT_ON_MAC_CONF                explicit override
#   2. first argument — a VM data directory, or a .conf file directly
#   3. ./protect-on-mac.conf               when run from inside the VM dir
#   4. ../vm-data/protect-on-mac.conf      sibling VM data dir (host scripts
#                                          live in <vm>/host, data in
#                                          <vm>/vm-data) — the normal case
#                                          when run as ./host/start-...
#   5. alongside this script               legacy single-VM layout
# So a VM is started with:  ./start-protect-vm.sh /path/to/that-vm/vm-data
# The resolved path is exported, so the helpers this script launches
# (control-host-helper, smartctl proxy, snapshot) all find the same conf.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${PROTECT_ON_MAC_CONF:-}"
if [ -z "$CONF_FILE" ] && [ -n "${1:-}" ]; then
    if [ -d "$1" ] && [ -f "$1/protect-on-mac.conf" ]; then
        CONF_FILE="$1/protect-on-mac.conf"; shift
    elif [ -f "$1" ] && [ "${1##*.}" = "conf" ]; then
        CONF_FILE="$1"; shift
    fi
fi
[ -z "$CONF_FILE" ] && [ -f "$PWD/protect-on-mac.conf" ] \
    && CONF_FILE="$PWD/protect-on-mac.conf"
# Sibling vm-data dir: <vm>/host/start-protect-vm.sh -> <vm>/vm-data/...conf.
# This is where stand-up.sh puts each VM's conf, so it must win over the
# legacy alongside-the-script copy below (which is often a stale example).
if [ -z "$CONF_FILE" ]; then
    _vm_data_conf="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)/vm-data/protect-on-mac.conf"
    [ -f "$_vm_data_conf" ] && CONF_FILE="$_vm_data_conf"
fi
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/protect-on-mac.conf}"
export PROTECT_ON_MAC_CONF="$CONF_FILE"

if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: Config file not found:" >&2
    echo "  $CONF_FILE" >&2
    echo "" >&2
    echo "Each VM's config lives in its data directory. Start a VM with:" >&2
    echo "  ./start-protect-vm.sh /path/to/<vm>/vm-data" >&2
    echo "" >&2
    echo "If you have not built a VM yet, run stand-up.sh first — it" >&2
    echo "creates the config and builds the VM." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

# Validate required values. The config file might be incomplete or have
# the example placeholders still in place.
# NIC_MAC selects which host interface to bridge through. Two forms:
#   unset / "auto" — pick the interface that currently holds the primary
#                    (flagless) default route. Roams with the host so a
#                    laptop that's docked-Ethernet at work and Wi-Fi at
#                    home bridges through the right adapter each time.
#   colon-hex MAC  — pin a specific adapter. Matched against both
#                    networksetup's hardware MAC and ifconfig's live MAC,
#                    so a randomized Wi-Fi address works.
if [ "${NIC_MAC:-}" = "aa:bb:cc:dd:ee:ff" ]; then
    echo "ERROR: NIC_MAC still has the example placeholder value." >&2
    echo "Set it to a MAC, leave it unset, or use \"auto\":" >&2
    echo "  $CONF_FILE" >&2
    exit 1
fi

# NIC_MAC identifies the host interface to bridge to. The VM must present
# a DIFFERENT MAC than that interface's own: with vmnet-bridged, a guest
# whose MAC equals the bridged host adapter's MAC collides on the L2
# segment and QEMU aborts at launch ("Abort trap: 6").
#
# When VM_MAC is unset, use a per-VM address that is BOTH unique and
# stable. A hash of the disk path would be stable but NOT unique — every
# fresh install shares the default VM_DISK path and would collide. So:
# generate a random locally-administered MAC (QEMU's 52:54:00 OUI) once,
# the first time this VM starts, and persist it next to the VM's data.
# Every later boot reads it back, so the DHCP identity stays put, and a
# second VM gets its own random address.
# A valid 48-bit MAC in colon-hex form. Anything else (empty, truncated by
# an interrupted write, hand-edited garbage) is rejected: an invalid mac=
# arg makes QEMU fail device realization and die in the chardev/yank
# teardown path — the same "Abort trap: 6" a MAC collision produces.
mac_is_valid() {
    printf '%s' "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
}
if [ -z "${VM_MAC:-}" ]; then
    VM_MAC_FILE="$VM_DATA_DIR/vm.mac"
    VM_MAC=""
    if [ -f "$VM_MAC_FILE" ]; then
        VM_MAC=$(tr -d '[:space:]' < "$VM_MAC_FILE")
        mac_is_valid "$VM_MAC" || {
            echo "WARNING: $VM_MAC_FILE is empty or malformed — regenerating" >&2
            VM_MAC=""
        }
    fi
    if [ -z "$VM_MAC" ]; then
        VM_MAC="52:54:00:$(openssl rand -hex 3 \
            | sed 's/\(..\)\(..\)\(..\)/\1:\2:\3/')"
        echo "$VM_MAC" > "$VM_MAC_FILE"
        echo "Generated VM MAC $VM_MAC (saved to $VM_MAC_FILE)"
    fi
elif ! mac_is_valid "$VM_MAC"; then
    echo "ERROR: VM_MAC is set but not a valid MAC address: '$VM_MAC'" >&2
    echo "Use colon-hex form (e.g. 52:54:00:12:34:56) or unset it to" >&2
    echo "have one generated." >&2
    exit 1
fi
# The VM_MAC vs bridge MAC collision check happens after the host
# interface is resolved below — BRIDGE_MAC (the live MAC of whichever
# adapter we end up bridging through) is the right comparand, not
# whatever string is sitting in NIC_MAC.

###############################################################################
# Helpers
###############################################################################

# Resolve a USB disk to its /dev/diskN device node by ATA serial number.
#
# How it works:
#   ioreg dumps the IOKit registry, which includes nested USB device
#   information. For each USB block device, we find the "USB Serial Number"
#   (which is the ATA serial passed through by the enclosure firmware) and
#   the corresponding "BSD Name" (the macOS device node).
#
#   We use LC_ALL=C because ioreg can produce non-UTF8 bytes in some entries,
#   and awk in the default locale throws "multibyte conversion failure"
#   errors when it encounters them. Forcing C locale makes awk treat
#   bytes as bytes.
#
#   The whitespace-stripping `xargs` on the target is because USB enclosure
#   firmware sometimes pads serial numbers with leading spaces. Without
#   stripping, the comparison would never match.
resolve_disk_by_serial() {
    local target="$1"
    target=$(echo "$target" | xargs)

    LC_ALL=C ioreg -p IOService -l -w 0 | LC_ALL=C awk -v target="$target" '
        # Match the serial number line. Extract everything between the
        # quotes after the equals sign, strip surrounding whitespace.
        /"USB Serial Number" = "/ {
            s = $0
            sub(/.*"USB Serial Number" = "/, "", s)
            sub(/".*/, "", s)
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            current_serial = s
        }
        # When we hit a BSD Name line for a disk device, if its serial
        # matches the target, print the device name and exit.
        /"BSD Name" = "disk[0-9]+"$/ && current_serial == target {
            match($0, /disk[0-9]+/)
            print substr($0, RSTART, RLENGTH)
            exit
        }
    '
}

# Resolve an ethernet adapter to its en* device name by MAC address.
# Works with any network adapter — built-in ethernet, USB, Thunderbolt.
#
# Two MACs, two tools:
#   networksetup -listallhardwareports reports each port's BURNED-IN
#   hardware MAC. ifconfig reports the LIVE MAC actually on the wire —
#   which differs on Wi-Fi, where macOS "Private Wi-Fi Address" assigns a
#   randomized locally-administered MAC PER SSID, rotating when the Mac
#   roams between networks.
#
# NIC_MAC should be the hardware MAC: it's stable across SSIDs and
# reboots, and only identifies which en* device to bridge through (the AP
# sees VM_MAC, not NIC_MAC). networksetup is checked first for that
# reason. The ifconfig fallback exists only so a NIC_MAC accidentally
# copied from ifconfig still resolves — it works today but breaks when
# Wi-Fi roams, so the launcher's error dump nudges users back to the hw
# MAC if resolution fails.
resolve_nic_by_mac() {
    local target dev mac
    target=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    dev=$(networksetup -listallhardwareports | awk -v target="$target" '
        /^Device:/ { dev=$2 }
        /^Ethernet Address:/ {
            if (tolower($3) == target) { print dev; exit }
        }
    ')
    if [ -n "$dev" ]; then
        echo "$dev"
        return 0
    fi

    # Fallback: live MAC per interface (catches randomized Wi-Fi MACs).
    for dev in $(networksetup -listallhardwareports \
                 | awk '/^Device:/ { print $2 }'); do
        mac=$(ifconfig "$dev" 2>/dev/null \
              | awk '/[ \t]ether /{ print tolower($2); exit }')
        if [ -n "$mac" ] && [ "$mac" = "$target" ]; then
            echo "$dev"
            return 0
        fi
    done
}

# The host interface that currently holds the primary (flagless) IPv4
# default route. `route -n get default` returns exactly that — the one
# macOS itself uses for un-bound outbound traffic — so it follows the
# Service Order and roams cleanly between locations (dock at work,
# Wi-Fi at home, etc.). Returns the en* device name or empty.
primary_default_iface() {
    route -n get default 2>/dev/null \
        | awk '/^[[:space:]]*interface:/ { print $2; exit }'
}

###############################################################################
# Resolve hardware
###############################################################################

# Ethernet. If we can't find the NIC, dump available adapters and exit.
# This catches "I unplugged the dock" or "the adapter's MAC changed" cases
# with a clear error message instead of QEMU failing cryptically later.
if [ -z "${NIC_MAC:-}" ] || [ "$NIC_MAC" = "auto" ]; then
    EN=$(primary_default_iface)
    if [ -z "$EN" ]; then
        echo "ERROR: NIC_MAC is auto but no primary IPv4 default route" >&2
        echo "exists on this host — connect it to a network, or pin" >&2
        echo "NIC_MAC to a specific adapter in:" >&2
        echo "  $CONF_FILE" >&2
        exit 1
    fi
    _en_source="primary default route"
else
    EN=$(resolve_nic_by_mac "$NIC_MAC")
    if [ -z "$EN" ]; then
        echo "ERROR: Could not find ethernet adapter with MAC $NIC_MAC" >&2
        echo "Available adapters (hardware MAC / live MAC):" >&2
        for _dev in $(networksetup -listallhardwareports \
                      | awk '/^Device:/ { print $2 }'); do
            _hw=$(networksetup -getmacaddress "$_dev" 2>/dev/null \
                  | awk '{ print $3 }')
            _live=$(ifconfig "$_dev" 2>/dev/null \
                    | awk '/[ \t]ether /{ print $2; exit }')
            echo "  $_dev  hw=${_hw:-?}  live=${_live:-?}" >&2
        done
        echo "Set NIC_MAC to a hw= value, OR set NIC_MAC=\"auto\" to" >&2
        echo "bridge through whichever adapter currently owns the" >&2
        echo "primary default route." >&2
        exit 1
    fi
    _en_source="NIC_MAC $NIC_MAC"
fi

# The live MAC of whichever interface we ended up resolving — the one
# actually on the wire. Used below to detect a guest/host MAC collision,
# which is what triggered the "Abort trap: 6" earlier in this saga.
BRIDGE_MAC=$(ifconfig "$EN" 2>/dev/null \
             | awk '/[ \t]ether /{ print tolower($2); exit }')
echo "Ethernet: $EN ($_en_source; live MAC ${BRIDGE_MAC:-unknown};" \
     "VM presents $VM_MAC)"

if [ -n "$BRIDGE_MAC" ] \
   && [ "$(echo "$VM_MAC" | tr 'A-F' 'a-f')" = "$BRIDGE_MAC" ]; then
    echo "ERROR: VM_MAC ($VM_MAC) equals the bridged interface's live" >&2
    echo "  MAC ($BRIDGE_MAC on $EN). A bridged VM cannot present the" >&2
    echo "  host adapter's own MAC — QEMU aborts at launch. Unset" >&2
    echo "  VM_MAC (one is generated) or set it to a different" >&2
    echo "  locally-administered address." >&2
    exit 1
fi

###############################################################################
# Diagnostics helper
###############################################################################

# Print all currently-connected external disks and their ATA serial numbers.
# Used in error messages so the user can see what's actually attached when
# a configured disk can't be found.
print_connected_disks() {
    echo "Connected disks and their serials:" >&2
    for d in $(diskutil list -plist external physical 2>/dev/null | \
               grep -oE 'disk[0-9]+' | sort -u); do
        echo "  /dev/$d:" >&2
        smartctl -i "/dev/$d" 2>/dev/null | grep "Serial Number" | sed 's/^/    /' >&2
    done
}

###############################################################################
# Resolve disks
###############################################################################

# True if the host disk a qcow2 file lives on is solid-state. Used to
# decide whether to attach the image with discard=unmap: on an SSD/NVMe
# backing, guest TRIM punches holes so the qcow2 stays sparse, and the
# disk can honestly present as a TRIM-capable SSD. On a rotational
# backing it stays a plain HDD (a real HDD does not TRIM).
backing_is_ssd() {
    local path="$1" vol
    vol="$(df "$path" 2>/dev/null | awk 'NR==2 {print $1}')"
    [ -n "$vol" ] || return 1
    diskutil info "$vol" 2>/dev/null \
        | grep -qE 'Solid State:[[:space:]]*Yes'
}

# Walk DISK_SERIALS and resolve each one to its current /dev/diskN. We use
# the serial number as the QEMU device serial too, so inside the VM
# `lsblk -o NAME,SERIAL` shows the real disk identities — useful for
# correlating SMART data, mdadm output, etc.
#
# We collect all failures before bailing out, so a user with seven disks
# missing doesn't have to fix-and-retry seven times. The connected-disks
# diagnostic is printed once at the end, listing everything we did find.
DISK_ARGS=()
MISSING_SERIALS=()
MAP_ENTRIES=()
for serial in "${DISK_SERIALS[@]}"; do
    bsd=$(resolve_disk_by_serial "$serial")
    if [ -z "$bsd" ]; then
        MISSING_SERIALS+=("$serial")
        continue
    fi
    echo "Disk: /dev/$bsd ($serial)"
    DISK_ARGS+=(
        -drive "if=none,id=disk_$serial,file=/dev/$bsd,format=raw,cache=$DISK_CACHE,aio=$DISK_AIO"
        -device "scsi-hd,bus=scsi0.0,drive=disk_$serial,serial=$serial"
    )
    # serial<TAB>kind<TAB>target — consumed by the optional smartctl proxy.
    MAP_ENTRIES+=("$serial"$'\t'"disk"$'\t'"/dev/$bsd")
done

if [ "${#MISSING_SERIALS[@]}" -gt 0 ]; then
    echo "" >&2
    echo "ERROR: Could not find disk(s) with the following serial(s):" >&2
    for s in "${MISSING_SERIALS[@]}"; do
        echo "  - $s" >&2
    done
    echo "" >&2
    print_connected_disks
    exit 1
fi

# Disk images. Each qcow2 in STORAGE_IMAGES gets attached as a virtual
# disk. These appear after any raw disks in the VM, as /dev/sdX devices
# in the order listed.
#
# Each STORAGE_IMAGES entry is "path|serial" — the qcow2 file path and
# the serial number the VM should see for that disk. The serial appears
# in lsblk -o NAME,SERIAL inside the VM and (importantly) is what the
# smartctl proxy uses to identify the disk if you've enabled host-side
# SMART forwarding. Keep serials unique across all attached disks.
IMG_ARGS=()
idx=0
for entry in "${STORAGE_IMAGES[@]}"; do
    # Parse "path|serial". If no | is present, treat the whole entry as
    # the path and synthesize a serial from the basename — backward
    # compatibility with older configs.
    if [[ "$entry" == *"|"* ]]; then
        img="${entry%%|*}"
        serial="${entry##*|}"
    else
        img="$entry"
        serial="img-$(basename "$entry" .qcow2)"
        echo "WARNING: STORAGE_IMAGES entry has no serial — using '$serial'" >&2
        echo "         Update config to 'path|serial' format for stable identity." >&2
    fi

    if [ ! -f "$img" ]; then
        echo "ERROR: Storage image not found: $img" >&2
        exit 1
    fi
    # The smartctl proxy host helper resolves this path to the physical
    # disk it lives on, so the map needs an absolute path.
    case "$img" in /*) ;; *) img="$PWD/$img" ;; esac

    # discard=unmap only when the qcow2 lives on an SSD/NVMe — keeps the
    # image sparse via guest TRIM and lets it present as a TRIM SSD.
    img_discard=ignore
    backing_is_ssd "$img" && img_discard=unmap

    id="img_${idx}"
    echo "Storage image (serial: $serial, discard: $img_discard):"
    echo "  $img"
    # rotation_rate=1 marks the disk as non-rotating (SSD) — a qcow2 file
    # has no platter. Inside the VM this shows as /sys/block/sdX/queue/
    # rotational=0, which is how provision-storage.sh tells an image-backed
    # disk from a raw-passthrough spinning disk (and only skips the RAID
    # resync, which would inflate the qcow2, for the all-image case).
    IMG_ARGS+=(
        -drive "if=none,id=$id,file=$img,format=qcow2,cache=$DISK_CACHE,aio=$DISK_AIO,discard=$img_discard"
        -device "scsi-hd,bus=scsi0.0,drive=$id,serial=$serial,rotation_rate=1"
    )
    # serial<TAB>kind<TAB>target — for image disks the target is the
    # qcow2 path; the host helper resolves it to its backing disk.
    MAP_ENTRIES+=("$serial"$'\t'"image"$'\t'"$img")
    idx=$((idx + 1))
done

###############################################################################
# Serial → device map (for the optional smartctl proxy)
###############################################################################
#
# The optional smartctl proxy lets Protect's UI show real disk health by
# forwarding SMART queries from inside the VM back to this host. Each line
# is "serial<TAB>kind<TAB>target":
#
#   <serial>  disk   /dev/diskN          raw-passthrough disk (DISK_SERIALS)
#   <serial>  image  /path/to/disk.qcow2 disk image (STORAGE_IMAGES)
#
# The VM sends the disk's serial; the host helper looks it up here. For a
# passthrough disk it queries /dev/diskN directly; for an image it resolves
# the qcow2 to the physical disk it lives on and queries that. macOS
# renumbers /dev/diskN on every reconnect, so the map is rewritten on every
# VM start.
#
# Written unconditionally and harmless if the proxy isn't set up. It lives
# under VM_DATA_DIR (not /var/run) so start-protect-vm.sh can write it
# without root, and the host helper — which runs as the same macOS user —
# can read it. See the README "smartctl proxy" section.
DISK_MAP="${DISK_MAP:-$VM_DATA_DIR/disk-serial.map}"
if [ -n "$DISK_MAP" ]; then
    if {
        for e in "${MAP_ENTRIES[@]}"; do
            printf '%s\n' "$e"
        done
    } > "$DISK_MAP" 2>/dev/null; then
        echo "Disk serial map (${#MAP_ENTRIES[@]} disk(s)):"
        echo "  $DISK_MAP"
    else
        echo "WARNING: could not write disk serial map $DISK_MAP" >&2
        echo "         The smartctl proxy (if enabled) will fall back to" >&2
        echo "         local SMART data until this is writable." >&2
    fi
fi

###############################################################################
# Console handling
###############################################################################
#
# We have two ways to run the VM:
#
#   1. INTERACTIVE: started from a terminal. The console is your terminal —
#      typing in this window goes straight to the VM's serial console. This
#      is the standard way to run a VM you're actively working with.
#
#   2. BACKGROUND: started by launchd, ssh-with-nohup, or similar. There's
#      no terminal attached. We expose the console as a unix socket so you
#      can attach with attach-console.sh from another shell when needed.
#      All console output is logged to a file regardless.
#
# We auto-detect which mode we're in by checking if stdin is a tty.
# Interactive runs always have a tty; daemons never do.
#
# Why this matters: when running under launchd, having the console available
# via socket means you can still log into the VM via console even if the
# network is broken. This is the same emergency-recovery pathway you'd use
# on a real UNVR via its serial header.

# Paths used in background mode. These default to /var/run/ paths which
# are auto-cleaned on reboot. attach-console.sh reads CONSOLE_SOCKET to
# find the socket. Values from the config file take precedence if set.
CONSOLE_SOCKET="${CONSOLE_SOCKET:-/var/run/protect-vm.console.sock}"
CONSOLE_LOG="${CONSOLE_LOG:-/var/log/protect-vm.console.log}"

# QMP (QEMU Machine Protocol) socket. Used by snapshot.sh to pause/resume
# the VM so snapshots can be taken without a full shutdown. Always exposed
# regardless of console mode — there's no downside to having it available.
QMP_SOCKET="${QMP_SOCKET:-/var/run/protect-vm.qmp.sock}"

# A second, dedicated QMP monitor for the background shutdown-reason
# reader near the end of this script. Kept separate from QMP_SOCKET so the
# reader's always-open connection never contends with snapshot.sh, which
# briefly holds QMP_SOCKET for live snapshots (a QMP socket serves only
# one client at a time).
#
# Unlike QMP_SOCKET, QEMU is the CLIENT here (server=off): the reader runs
# as this unprivileged user and owns the socket, so it needs no sudo. The
# socket therefore lives under VM_DATA_DIR — a non-root user cannot create
# one in root-owned /var/run (same constraint as the control channel).
QMP_EVENT_SOCKET="${QMP_EVENT_SOCKET:-$VM_DATA_DIR/protect-vm.qmp-events.sock}"

# QMP is appended to both modes since it doesn't interfere with anything.
# QMP_SOCKET: QEMU is the server (snapshot.sh connects on demand).
# QMP_EVENT_SOCKET: QEMU is the client of the reader's listener.
QMP_ARGS=(
    -qmp "unix:$QMP_SOCKET,server=on,wait=off"
    -chardev "socket,id=qmpevt,path=$QMP_EVENT_SOCKET,server=off,reconnect-ms=2000"
    -mon "chardev=qmpevt,mode=control"
)

# Control channel — a virtio-serial port the VM uses to ask the host for
# a small fixed set of actions (take a snapshot; run a real SMART query).
# It has no IP, so it can't collide with any LAN subnet, and UniFi OS
# never sees it — it's a character device, not a NIC. The host side is
# control-host-helper.sh; the guest side is /usr/local/bin/protect-on-mac-ctl.
# control-host-helper.sh owns the socket (it's the listener); QEMU is the
# client, so server=off. reconnect-ms lets QEMU tolerate the listener not
# being up yet, and reconnect if it restarts. (QEMU 9.2+ uses reconnect-ms;
# the older 'reconnect' in whole seconds was removed in QEMU 10.1.)
#
# The socket lives under VM_DATA_DIR, not /var/run: the listener runs as
# the normal (non-root) user and cannot create a socket in root-owned
# /var/run. QEMU runs as root and can connect to it regardless.
CONTROL_SOCKET="${CONTROL_SOCKET:-$VM_DATA_DIR/protect-vm.control.sock}"
CONTROL_ARGS=(
    -device virtio-serial-pci
    -chardev "socket,id=ctrl0,path=$CONTROL_SOCKET,server=off,reconnect-ms=2000"
    -device "virtserialport,chardev=ctrl0,name=org.protect-on-mac.control"
)
echo "Control socket: $CONTROL_SOCKET"

if [ -t 0 ]; then
    # Interactive: serial console + QEMU monitor multiplexed onto this
    # terminal. We build the chardev explicitly rather than using
    # -nographic so we can set signal=off: with it, Ctrl-C is passed
    # THROUGH to the guest (so it aborts a guest command, as expected)
    # instead of being delivered to QEMU as SIGINT and killing the VM.
    # mux=on keeps the Ctrl-A escape: Ctrl-A C toggles serial/monitor,
    # Ctrl-A X quits QEMU.
    CONSOLE_ARGS=(
        -display none
        -chardev stdio,id=console,signal=off,mux=on
        -serial chardev:console
        -mon chardev=console,mode=readline
    )
    echo "Mode: interactive (console on this terminal; Ctrl-A X to quit)"
else
    # Background: console via unix socket + log file.
    # The chardev definition handles both the socket server and the log
    # in one place. server=on,wait=off means the socket exists but the
    # VM doesn't block waiting for someone to connect.
    CONSOLE_ARGS=(
        -display none
        -chardev "socket,id=charconsole,path=$CONSOLE_SOCKET,server=on,wait=off,logfile=$CONSOLE_LOG,logappend=on"
        -serial chardev:charconsole
        -monitor none
    )
    echo "Mode: background"
    echo "  console socket: $CONSOLE_SOCKET"
    echo "  console log:    $CONSOLE_LOG"
fi
echo "QMP socket: $QMP_SOCKET"

###############################################################################
# Scripts ISO
#
# If a scripts ISO is defined and exists, attach it to the VM as a CD-ROM.
# The VM ignores it unless someone explicitly mounts /dev/sr0.
#
# Interactive mode also offers to create the ISO (if missing) or
# regenerate it (if present), so you can refresh in-VM scripts without
# having to run make-scripts-iso.sh manually.
#
# Background mode (launchd) skips prompts entirely — uses the ISO if
# present, skips ISO attachment if not.
###############################################################################

CDROM_ARGS=()
if [ -n "${SCRIPTS_ISO:-}" ]; then
    # The make-scripts-iso.sh tool ships next to this script
    MAKE_ISO="$SCRIPT_DIR/make-scripts-iso.sh"

    if [ -t 0 ]; then
        # Interactive — prompt as appropriate
        if [ ! -f "$SCRIPTS_ISO" ]; then
            echo ""
            echo "Scripts ISO not found at: $SCRIPTS_ISO"
            if [ -x "$MAKE_ISO" ]; then
                read -r -p "Create it now? [Y/n]: " response
                case "$response" in
                    [nN]|[nN][oO]) echo "Skipping ISO creation." ;;
                    *)
                        "$MAKE_ISO" "$SCRIPTS_ISO"
                        ;;
                esac
            else
                echo "(make-scripts-iso.sh not found; skipping)"
                echo "  $MAKE_ISO"
            fi
        else
            # ISO already exists — ask if user wants to regenerate it.
            # Default no, since most starts don't need a fresh ISO.
            echo ""
            echo "Scripts ISO found at: $SCRIPTS_ISO"
            if [ -x "$MAKE_ISO" ]; then
                read -r -p "Regenerate from current scripts? [y/N]: " response
                case "$response" in
                    [yY]|[yY][eE][sS])
                        "$MAKE_ISO" "$SCRIPTS_ISO"
                        ;;
                    *) echo "Using existing ISO." ;;
                esac
            fi
        fi
    fi
    # In background mode we skip the prompts entirely and just use
    # whatever ISO is on disk.

    if [ -f "$SCRIPTS_ISO" ]; then
        CDROM_ARGS=(
            -drive "if=none,id=scripts,file=$SCRIPTS_ISO,format=raw,media=cdrom,readonly=on"
            -device "scsi-cd,bus=scsi0.0,drive=scripts"
        )
        echo "Attaching scripts ISO:"
        echo "  $SCRIPTS_ISO"
    else
        echo "No scripts ISO to attach (proceeding without)."
    fi
fi

###############################################################################
# Sanity checks
###############################################################################

# Verify all required files exist before invoking QEMU. QEMU errors are
# usually descriptive enough but checking here gives clearer feedback
# when, e.g., the VM disk has been moved or homebrew QEMU was upgraded
# to a path with a different version number.
for f in "$VM_DISK" "$EFI_CODE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: required file not found:" >&2
        echo "  $f" >&2
        exit 1
    fi
done

###############################################################################
# UEFI variable store — recreated fresh on every boot
###############################################################################
#
# This VM boots via the removable-media path \EFI\BOOT\BOOTAA64.EFI,
# which edk2 rediscovers from an empty varstore on each boot. A persisted
# varstore is a liability here, not a feature: edk2 writes a BootOrder
# that can end up preferring the built-in UEFI Shell, and every later
# boot then lands in that shell instead of the OS. Starting each boot
# with an empty varstore (no BootOrder) makes edk2 fall back to the
# removable path and boot the OS. Nothing in this VM needs persistent
# UEFI variables.

echo "Resetting UEFI variable store (fresh boot environment)"
dd if=/dev/zero of="$EFI_VARS" bs=1m count=64 status=none

###############################################################################
# Launch
###############################################################################

echo ""
echo "Starting VM..."

# QEMU command-line breakdown:
#
#   -machine virt,accel=hvf
#       The "virt" machine type is a generic ARM platform suitable for
#       VMs. accel=hvf enables Apple's Hypervisor Framework on M-series
#       Macs — this is essentially native CPU virtualization with very
#       low overhead.
#
#   -cpu host
#       Pass through the host CPU's feature flags. The VM sees the same
#       capabilities (NEON, crypto extensions, etc.) the host CPU has.
#
#   -smp $VM_CPUS / -m $VM_RAM
#       CPU and RAM allocation. The VM gets exactly these resources;
#       the host doesn't share dynamically.
#
#   -drive if=pflash...EFI_CODE / EFI_VARS
#       UEFI firmware. The first (unit=0) is read-only EDK2 firmware
#       code. The second (unit=1) is writable variable storage where
#       the firmware persists boot configuration. Both are required for
#       UEFI boot of the Debian VM.
#
#   -drive if=virtio,file=$VM_DISK,format=qcow2
#       The VM's main disk (the Debian rootfs). Uses virtio for best
#       performance. This is a regular file on the host's APFS volume.
#
#   -device virtio-scsi-pci,id=scsi0
#       Adds a virtio-scsi controller. We use this instead of plain
#       virtio-blk for the data disks because virtio-scsi supports
#       serial numbers (which we use to identify disks inside the VM).
#
#   "${DISK_ARGS[@]}" "${IMG_ARGS[@]}"
#       The dynamically-built disk arguments from above. Each raw disk
#       (DISK_ARGS) and each disk image (IMG_ARGS) gets a -drive and
#       -device pair.
#
#   -netdev vmnet-bridged,id=net0,ifname=$EN
#       Bridge the VM directly to the host's network adapter. The VM
#       gets its own MAC and IP on your physical network — no NAT.
#       This is what allows cameras and door hubs to talk to the VM
#       as if it were a physical controller.
#
#   -device virtio-net-pci,netdev=net0,mac=$VM_MAC
#       Network device. VM_MAC is generated per-VM and persisted, must
#       differ from the bridged adapter's live MAC (checked above), and
#       stays stable across reboots so the VM has a consistent DHCP
#       identity even as NIC_MAC="auto" picks different host adapters
#       in different locations.
#
#   "${CONSOLE_ARGS[@]}"
#       Either `-nographic` (interactive) or `-chardev socket... -serial
#       chardev... -display none` (background). See "Console handling"
#       above for why.
#
#   "${QMP_ARGS[@]}"
#       QEMU Machine Protocol socket. snapshot.sh uses this to pause and
#       resume the VM during live snapshots, so we don't need to shut the
#       VM down to take one. See snapshot.sh for the workflow.
#
#   "${CDROM_ARGS[@]}"
#       Optional scripts ISO attached as a CD-ROM. Lets the VM mount
#       /dev/sr0 to refresh its copies of install/update scripts. Empty
#       array if no ISO is configured or available. See "Scripts ISO"
#       section above.
#
# Start the control-channel listener (host side of the virtio-serial
# port) before QEMU. It runs as the normal user and owns the socket;
# QEMU connects to it as a client. The trap stops it whenever this
# script exits — i.e. when QEMU does — with a plain kill, no sudo.
CONTROL_HELPER="$SCRIPT_DIR/control-host-helper.sh"
control_pid=""
if [ -f "$CONTROL_HELPER" ]; then
    # Run via `bash` so a missing execute bit (exec bits don't survive
    # every copy) doesn't disable the channel.
    bash "$CONTROL_HELPER" listen &
    control_pid=$!
    # Give the listener up to ~5s to create the socket, so QEMU connects
    # on its first try. reconnect-ms covers any remaining gap.
    for _ in $(seq 1 50); do
        [ -S "$CONTROL_SOCKET" ] && break
        sleep 0.1
    done
    [ -S "$CONTROL_SOCKET" ] \
        || echo "WARNING: control socket not up yet — channel may be delayed" >&2
else
    echo "WARNING: control channel disabled — helper not found:" >&2
    echo "  $CONTROL_HELPER" >&2
fi
QMP_REASON_FILE="$(mktemp -t protect-vm-qmp-reason)"
# shellcheck disable=SC2064
trap '
    [ -n "$control_pid" ] && kill "$control_pid" 2>/dev/null
    [ -n "${qmp_reader_pid:-}" ] && kill "$qmp_reader_pid" 2>/dev/null
    rm -f "$QMP_REASON_FILE"
' EXIT

# QEMU runs under -no-reboot: a guest reboot makes QEMU EXIT rather than
# issue a warm reset, because a warm reset hangs the QEMU/EDK2 firmware on
# this platform (it comes back with "Image start failed" and never reaches
# GRUB). Every start is therefore a clean cold boot.
#
# A background QMP reader records WHY QEMU exited — "guest-reset" (the
# guest asked to reboot) vs "guest-shutdown" (a real power-off, e.g. from
# the Protect web UI). This loop then cold-restarts QEMU on a reboot and
# stops on a power-off.
#
# The exit status mirrors the outcome so launchd (KeepAlive with
# SuccessfulExit=false) does the right thing: a power-off exits 0 and the
# daemon stays down; a crash exits non-zero and launchd relaunches. A
# reboot never exits the loop at all — it just re-enters it.

# Resolve qemu to an absolute path: the sudo NOPASSWD rule is written with
# an absolute path, so invoking qemu the same way makes the match reliable
# regardless of sudo's secure_path.
QEMU_BIN="$(command -v qemu-system-aarch64 || echo /opt/homebrew/bin/qemu-system-aarch64)"

# discard=unmap for the OS disk too, when its qcow2 is on an SSD/NVMe —
# the DB churn on /data keeps the image growing otherwise.
VM_DISK_DISCARD=ignore
backing_is_ssd "$VM_DISK" && VM_DISK_DISCARD=unmap

while :; do
    : > "$QMP_REASON_FILE"

    # Reader: LISTEN on the event socket as this unprivileged user; QEMU
    # connects to it as a client (the -chardev server=off above). No sudo
    # is involved. Once QEMU connects, block until the SHUTDOWN event and
    # record its reason.
    (
        python3 - "$QMP_EVENT_SOCKET" "$QMP_REASON_FILE" <<'PYEOF'
import json, os, socket, sys

sock_path, out_path = sys.argv[1], sys.argv[2]
try:
    os.unlink(sock_path)
except OSError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    srv.bind(sock_path)
    srv.listen(1)
    srv.settimeout(120)                          # QEMU connects well within
    conn, _ = srv.accept()
except (OSError, socket.timeout):
    sys.exit(0)                                  # QEMU never connected
conn.settimeout(None)                            # then block for the run
rx = conn.makefile("r", encoding="utf-8")
rx.readline()                                    # QMP greeting
conn.sendall(b'{"execute":"qmp_capabilities"}\n')  # events flow after this
for line in rx:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if msg.get("event") == "SHUTDOWN":
        reason = msg.get("data", {}).get("reason", "")
        try:
            with open(out_path, "w") as f:
                f.write(reason)
        except OSError:
            pass
        break
PYEOF
    ) &
    qmp_reader_pid=$!

    # Wait for the reader's socket to exist before launching QEMU. Without
    # this, QEMU may try to connect before python3 has bound and the
    # qmpevt chardev falls into its reconnect-ms loop on the first attempt
    # — that reconnect path has been seen to hit an intermittent yank-
    # registration bug in QEMU's chardev cleanup that aborts the process
    # ("Abort trap: 6", crash in yank_unregister_function). Same loop the
    # control socket uses above.
    for _ in $(seq 1 50); do
        [ -S "$QMP_EVENT_SOCKET" ] && break
        sleep 0.1
    done
    [ -S "$QMP_EVENT_SOCKET" ] \
        || echo "WARNING: qmpevt socket not up yet — QEMU may abort" >&2

    qemu_rc=0
    sudo "$QEMU_BIN" \
        -machine virt,accel=hvf \
        -cpu host \
        -smp "$VM_CPUS" \
        -m "$VM_RAM" \
        -no-reboot \
        -drive if=pflash,format=raw,unit=0,file="$EFI_CODE",readonly=on \
        -drive if=pflash,format=raw,unit=1,file="$EFI_VARS" \
        -drive if=virtio,file="$VM_DISK",format=qcow2,discard="$VM_DISK_DISCARD" \
        -device virtio-scsi-pci,id=scsi0 \
        "${DISK_ARGS[@]}" \
        "${IMG_ARGS[@]}" \
        "${CDROM_ARGS[@]}" \
        -netdev "vmnet-bridged,id=net0,ifname=$EN" \
        -device "virtio-net-pci,netdev=net0,mac=$VM_MAC" \
        "${CONSOLE_ARGS[@]}" \
        "${QMP_ARGS[@]}" \
        "${CONTROL_ARGS[@]}" || qemu_rc=$?

    # QEMU's -nographic puts this terminal in raw mode; it restores it on
    # a clean exit but not if it was killed or crashed. Restore it here so
    # a dead QEMU never leaves the terminal wedged (no echo, no newlines).
    if [ -t 0 ]; then stty sane 2>/dev/null || true; fi

    # The reader exits on its own when QEMU closes the QMP socket; wait so
    # the reason file is complete before we read it.
    wait "$qmp_reader_pid" 2>/dev/null || true
    qmp_reader_pid=""
    shutdown_reason="$(cat "$QMP_REASON_FILE" 2>/dev/null || true)"

    case "$shutdown_reason" in
        guest-reset)
            echo ""
            echo ">>> VM rebooted — cold-restarting QEMU."
            echo ""
            sleep 2                              # throttle a reboot loop
            continue
            ;;
        guest-shutdown)
            echo ""
            echo ">>> VM powered off. Not restarting."
            echo "    Re-run this script (or 'launchctl kickstart' the"
            echo "    daemon) to start it again."
            exit 0
            ;;
        *)
            echo ""
            echo ">>> QEMU exited (reason: ${shutdown_reason:-unknown}," \
                 "status $qemu_rc)."
            exit "${qemu_rc:-1}"
            ;;
    esac
done
