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
# - Optionally attaches a dedicated postgres SSD qcow2.
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
# All configuration lives in protect-on-mac.conf. Copy the example to
# get started:
#
#   cp protect-on-mac.conf.example protect-on-mac.conf
#   $EDITOR protect-on-mac.conf
#
# Override the config file location with the PROTECT_ON_MAC_CONF env var:
#   PROTECT_ON_MAC_CONF=/path/to/other.conf ./start-protect-vm.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${PROTECT_ON_MAC_CONF:-$SCRIPT_DIR/protect-on-mac.conf}"

if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: Config file not found at $CONF_FILE" >&2
    echo "" >&2
    echo "Copy the example and edit it:" >&2
    echo "  cp $SCRIPT_DIR/protect-on-mac.conf.example $CONF_FILE" >&2
    echo "  \$EDITOR $CONF_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

# Validate required values. The config file might be incomplete or have
# the example placeholders still in place.
if [ -z "${NIC_MAC:-}" ] || [ "$NIC_MAC" = "aa:bb:cc:dd:ee:ff" ]; then
    echo "ERROR: NIC_MAC not set or still has the example value." >&2
    echo "Edit $CONF_FILE and set it to your adapter's MAC." >&2
    echo "Find it with: networksetup -listallhardwareports" >&2
    exit 1
fi

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
# Why we use networksetup instead of ioreg:
#   The MAC address lives in the IOEthernetController class, but the
#   BSD device name (en0, en5, etc.) lives in IOEthernetInterface. The
#   parent/child relationship makes single-pass awk tricky. networksetup
#   shows both in a flat, easy-to-parse format.
resolve_nic_by_mac() {
    local target="$1"
    target=$(echo "$target" | tr '[:upper:]' '[:lower:]')

    networksetup -listallhardwareports | awk -v target="$target" '
        /^Hardware Port:/ { port=$0 }
        /^Device:/ { dev=$2 }
        /^Ethernet Address:/ {
            mac=tolower($3)
            if (mac == target) { print dev; exit }
        }
    '
}

###############################################################################
# Resolve hardware
###############################################################################

# Ethernet. If we can't find the NIC, dump available adapters and exit.
# This catches "I unplugged the dock" or "the adapter's MAC changed" cases
# with a clear error message instead of QEMU failing cryptically later.
EN=$(resolve_nic_by_mac "$NIC_MAC")
if [ -z "$EN" ]; then
    echo "ERROR: Could not find ethernet adapter with MAC $NIC_MAC" >&2
    echo "Available adapters:" >&2
    networksetup -listallhardwareports | grep -B2 -A1 "Ethernet Address" >&2
    exit 1
fi
echo "Ethernet: $EN ($NIC_MAC)"

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

    id="img_${idx}"
    echo "Storage image: $img (serial: $serial)"
    IMG_ARGS+=(
        -drive "if=none,id=$id,file=$img,format=qcow2,cache=$DISK_CACHE,aio=$DISK_AIO"
        -device "scsi-hd,bus=scsi0.0,drive=$id,serial=$serial"
    )
    idx=$((idx + 1))
done

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

# QMP is appended to both modes since it doesn't interfere with anything.
QMP_ARGS=(
    -qmp "unix:$QMP_SOCKET,server=on,wait=off"
)

if [ -t 0 ]; then
    # Interactive: console attached to this terminal via -nographic.
    # Ctrl-A C switches between serial console and QEMU monitor.
    CONSOLE_ARGS=(-nographic)
    echo "Mode: interactive (console on this terminal)"
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
    echo "Mode: background (console socket: $CONSOLE_SOCKET, log: $CONSOLE_LOG)"
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
                echo "(make-scripts-iso.sh not found at $MAKE_ISO; skipping)"
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
        echo "Attaching scripts ISO: $SCRIPTS_ISO"
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
for f in "$VM_DISK" "$EFI_VARS" "$EFI_CODE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required file not found: $f" >&2
        exit 1
    fi
done

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
#   -device virtio-net-pci,netdev=net0,mac=$NIC_MAC
#       Network device. We set the VM's MAC to match the physical adapter
#       so the VM has a stable identity on the network.
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
sudo qemu-system-aarch64 \
    -machine virt,accel=hvf \
    -cpu host \
    -smp "$VM_CPUS" \
    -m "$VM_RAM" \
    -drive if=pflash,format=raw,unit=0,file="$EFI_CODE",readonly=on \
    -drive if=pflash,unit=1,file="$EFI_VARS" \
    -drive if=virtio,file="$VM_DISK",format=qcow2 \
    -device virtio-scsi-pci,id=scsi0 \
    "${DISK_ARGS[@]}" \
    "${IMG_ARGS[@]}" \
    "${CDROM_ARGS[@]}" \
    -netdev "vmnet-bridged,id=net0,ifname=$EN" \
    -device "virtio-net-pci,netdev=net0,mac=$NIC_MAC" \
    "${CONSOLE_ARGS[@]}" \
    "${QMP_ARGS[@]}"
