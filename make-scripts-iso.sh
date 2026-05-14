#!/bin/bash
###############################################################################
# make-scripts-iso.sh
#
# Bundle the VM-side scripts into an ISO that can be attached to the VM
# as a CD-ROM. This is how you get the scripts into the VM during initial
# setup, before SSH from the host is reachable.
#
# WHY THIS EXISTS
#
# During Debian installation the VM uses QEMU's user-mode networking
# (NAT), which:
#   - Lets the VM reach the internet (for apt, etc.)
#   - Does NOT let the host reach the VM directly
#   - macOS doesn't reliably hairpin NAT either, so `scp` from the host
#     to the VM doesn't work
#
# After setup we switch to bridged networking and the VM is reachable
# from anywhere on the LAN — but not always from the host itself when
# using vmnet-bridged. The cleanest way to bootstrap is to skip the
# network entirely and hand the scripts to the VM via a virtual CD-ROM.
#
# WHAT GETS INCLUDED
#
# The four VM-side scripts:
#   - install-protect-baremetal.sh
#   - unifi-update.sh
#   - mount-storage.sh
#   - uninstall.sh
#
# Once installed, the VM is reachable from other LAN hosts via SSH, so
# future updates of these scripts can be copied in with scp from any
# non-host machine on the network. Or rebuild this ISO and re-attach.
#
# Usage:
#   ./make-scripts-iso.sh                            # Creates protect-on-mac-scripts.iso
#   ./make-scripts-iso.sh /path/to/output.iso        # Custom output path
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/protect-on-mac-scripts.iso}"

# Files to include in the ISO. We include the full repo so someone
# mounting the ISO sees everything that came with the project — the
# four VM-side scripts that get used during install, plus the host-side
# scripts and docs for reference. The host scripts aren't useful inside
# the VM directly, but having them present means the ISO is a complete
# self-contained copy of the project.
VM_SCRIPTS=(
    install-protect-baremetal.sh
    unifi-update.sh
    mount-storage.sh
    uninstall.sh
)

HOST_SCRIPTS=(
    start-protect-vm.sh
    attach-console.sh
    snapshot.sh
    install-launchd.sh
    make-scripts-iso.sh
)

OTHER_FILES=(
    README.md
    protect-on-mac.conf.example
    com.protect-on-mac.vm.plist
)

# Stage everything in a temp dir
STAGING=$(mktemp -d)
trap "rm -rf '$STAGING'" EXIT

echo ">>> Staging files..."
copy_if_exists() {
    local f="$1"
    if [ -f "$SCRIPT_DIR/$f" ]; then
        cp "$SCRIPT_DIR/$f" "$STAGING/"
        chmod +x "$STAGING/$f" 2>/dev/null || true
        echo "    $f"
    fi
}

for f in "${VM_SCRIPTS[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$f" ]; then
        echo "ERROR: required VM script $SCRIPT_DIR/$f not found" >&2
        exit 1
    fi
    cp "$SCRIPT_DIR/$f" "$STAGING/"
    chmod +x "$STAGING/$f"
    echo "    $f"
done

for f in "${HOST_SCRIPTS[@]}" "${OTHER_FILES[@]}"; do
    copy_if_exists "$f"
done

# Add an in-ISO README so when you mount this in the VM and don't
# remember why, `cat README.iso` tells you. We use README.iso to avoid
# clobbering the project's README.md in the same directory.
cat > "$STAGING/README.iso" <<'EOF'
Protect on Mac — VM-side bootstrap bundle.

Created by make-scripts-iso.sh on the host. Mount this in the VM at
/mnt/protect-on-mac (or any dedicated subdirectory — avoid /mnt itself
in case Protect/Ubiquiti software ever uses it).

    sudo mkdir -p /mnt/protect-on-mac
    sudo mount /dev/sr0 /mnt/protect-on-mac
    sudo cp /mnt/protect-on-mac/*.sh /root/
    sudo chmod +x /root/*.sh
    sudo umount /mnt/protect-on-mac

Then run the install:
    sudo bash /root/install-protect-baremetal.sh

The ISO contains the VM-side scripts (which you copy and run inside the
VM) plus the host-side scripts and docs (for reference — they're not
used inside the VM directly).
EOF

echo ""
echo ">>> Creating ISO..."
# hdiutil makehybrid is macOS's built-in ISO creator. Cross-platform
# alternatives:
#   - mkisofs (Linux):   mkisofs -o "$OUTPUT" -J -r "$STAGING"
#   - genisoimage:       genisoimage -o "$OUTPUT" -J -r "$STAGING"
if command -v hdiutil >/dev/null 2>&1; then
    hdiutil makehybrid -iso -joliet -o "$OUTPUT" "$STAGING" >/dev/null
elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -o "$OUTPUT" -J -r "$STAGING" 2>/dev/null
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -o "$OUTPUT" -J -r "$STAGING" 2>/dev/null
else
    echo "ERROR: No ISO creation tool found (hdiutil/mkisofs/genisoimage)" >&2
    exit 1
fi

echo ""
echo "Created: $OUTPUT"
echo ""
echo "To use during initial setup, add to your install-mode QEMU command:"
echo ""
echo "  -drive if=none,id=scripts,file=$OUTPUT,format=raw,media=cdrom \\"
echo "  -device scsi-cd,bus=scsi0.0,drive=scripts"
echo ""
echo "Then in the VM after Debian boots:"
echo ""
echo "  sudo mkdir -p /mnt/protect-on-mac"
echo "  sudo mount /dev/sr0 /mnt/protect-on-mac"
echo "  sudo cp /mnt/protect-on-mac/*.sh /root/"
echo "  sudo chmod +x /root/*.sh"
echo "  sudo umount /mnt/protect-on-mac"
echo "  sudo bash /root/install-protect-baremetal.sh"
echo ""
echo "The ISO also includes the host-side scripts and docs for reference."
echo "Browse the contents on macOS with:"
echo ""
echo "  hdiutil attach $OUTPUT"
echo "  ls /Volumes/$(basename "$OUTPUT" .iso)/"
