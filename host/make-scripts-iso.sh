#!/bin/bash
###############################################################################
# make-scripts-iso.sh
#
# Bundle the project tree into an ISO that can be attached to the VM as a
# CD-ROM. This is how you get the scripts into the VM during initial
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
# WHY A TARBALL, NOT A LOOSE TREE
#
# An ISO 9660 filesystem caps filenames at 31 characters, allows only one
# dot, and stores no Unix permissions — so a loose project tree on the
# ISO loses execute bits, truncates long names, and mangles multi-dot
# names. So the ISO carries a single gzipped tar of the project instead:
# tar preserves full names, the directory tree, and mode bits exactly.
# The tarball is named .tgz (one dot) so the ISO itself can't mangle it.
# A start-here.sh bootstrap rides alongside it for a one-step unpack.
#
# Usage:
#   ./make-scripts-iso.sh                       # -> ./protect-on-mac-scripts.iso
#   ./make-scripts-iso.sh /path/to/output.iso   # custom output path
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/protect-on-mac-scripts.iso}"
TARBALL_NAME="protect-on-mac.tgz"

# Locate the project root. make-scripts-iso.sh normally lives in host/
# with vm/ as a sibling — but in a flat deployment it can sit directly
# next to vm/. Accept either layout.
if [ -d "$SCRIPT_DIR/../vm/installers" ]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [ -d "$SCRIPT_DIR/vm/installers" ]; then
    REPO_ROOT="$SCRIPT_DIR"
else
    echo "ERROR: can't find vm/installers/ near this script:" >&2
    echo "  $SCRIPT_DIR" >&2
    echo "make-scripts-iso.sh must sit in host/ (with vm/ alongside)," >&2
    echo "or directly next to the vm/ directory." >&2
    exit 1
fi

if [ ! -f "$REPO_ROOT/vm/installers/install-protect-baremetal.sh" ]; then
    echo "ERROR: incomplete vm/ tree — missing:" >&2
    echo "  $REPO_ROOT/vm/installers/install-protect-baremetal.sh" >&2
    exit 1
fi
if [ ! -d "$REPO_ROOT/vm/storage/rootfs" ]; then
    echo "ERROR: incomplete vm/ tree — missing:" >&2
    echo "  $REPO_ROOT/vm/storage/rootfs/" >&2
    exit 1
fi

STAGING=$(mktemp -d)
trap "rm -rf '$STAGING'" EXIT

# Tar up the project tree. vm/ is the payload; host/ and capture/ ride
# along for reference. Excluded: the user's personal config, macOS
# noise, Python bytecode, and any previously-built ISO.
echo ">>> Packing the project tree into $TARBALL_NAME ..."
TAR_ITEMS=(vm)
for d in host capture; do
    [ -d "$REPO_ROOT/$d" ] && TAR_ITEMS+=("$d")
done
for f in README.md QUICKSTART.md LICENSE; do
    [ -f "$REPO_ROOT/$f" ] && TAR_ITEMS+=("$f")
done
# macOS tar records Apple xattrs (com.apple.quarantine, .provenance) as
# LIBARCHIVE.xattr.* pax headers. They're harmless data, but GNU tar in
# the VM prints "unknown extended header keyword" once per file. Stripping
# them here is unreliable (provenance is sticky — survives --no-xattrs and
# xattr -cr), so the extraction side handles it instead: start-here.sh
# untars with --warning=no-unknown-keyword.
tar -czf "$STAGING/$TARBALL_NAME" -C "$REPO_ROOT" \
    --exclude='host/protect-on-mac.conf' \
    --exclude='.DS_Store' \
    --exclude='._*' \
    --exclude='__pycache__' \
    --exclude='*.iso' \
    "${TAR_ITEMS[@]}"
echo "    packed: ${TAR_ITEMS[*]}"

# An in-ISO README so `cat README.iso` explains the bundle if needed.
cat > "$STAGING/README.iso" <<EOF
Protect on Mac — VM-side bootstrap bundle.

EASIEST — mount this CD-ROM in the VM and run start-here.sh as root. It
unpacks the project and runs the installer:

    mkdir -p /mnt/protect-on-mac
    mount /dev/sr0 /mnt/protect-on-mac
    bash /mnt/protect-on-mac/start-here.sh

BY HAND — the project tree is inside $TARBALL_NAME (a tar preserves full
filenames and execute bits, which a raw ISO filesystem does not):

    mount /dev/sr0 /mnt/protect-on-mac
    tar --warning=no-unknown-keyword \\
        -xzf /mnt/protect-on-mac/$TARBALL_NAME -C /root
    umount /mnt/protect-on-mac
    cd /root/vm/installers
    ./install-protect-baremetal.sh
EOF

# start-here.sh — one-step bootstrap so it's obvious what to do with the
# tarball. Finds the .tgz next to itself, unpacks it, runs the install.
cat > "$STAGING/start-here.sh" <<'EOF'
#!/bin/bash
###############################################################################
# start-here.sh — first-run bootstrap for the Protect VM.
#
# You're reading this because you mounted the protect-on-mac scripts
# CD-ROM. Run it in the VM, as root:
#
#     bash /mnt/protect-on-mac/start-here.sh
#
# It unpacks the project to /root and runs the installers.
###############################################################################
set -e

here="$(cd "$(dirname "$0")" && pwd)"
tarball="$(ls "$here"/*.tgz 2>/dev/null | head -1)"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this as root." >&2
    exit 1
fi
if [ -z "$tarball" ] || [ ! -f "$tarball" ]; then
    echo "ERROR: no project tarball (*.tgz) found next to this script." >&2
    exit 1
fi

echo "Unpacking the project to /root ..."
tar --warning=no-unknown-keyword -xzf "$tarball" -C /root
echo "Unpacked: /root/vm, /root/host, /root/capture."
echo ""
echo "install-protect-baremetal.sh builds the full Protect stack (~30m),"
echo "including the UNVR-faithful storage layer."
echo ""
# Default to running the installer. On the VM's first boot this script is
# launched by the autologin with nobody necessarily watching, so the prompt
# proceeds on its own after 30s — an unattended stand-up then runs the
# installer (which itself auto-reboots) with no input. A person at the
# console can still type 'n' to skip, or Enter to start immediately.
echo "Starting the install in 30 seconds."
echo "  Press Enter to start now, or type 'n' (then Enter) to skip."
ans=""
read -r -t 30 -p "Run it now? [Y/n]: " ans || ans="Y"
echo ""
case "$ans" in
    n|N)
        echo "Skipped. When you're ready:"
        echo "  cd /root/vm/installers"
        echo "  ./install-protect-baremetal.sh"
        exit 0 ;;
esac

cd /root/vm/installers
./install-protect-baremetal.sh

echo ""
echo "Install complete. Shut the VM down (systemctl poweroff), then"
echo "start it from the host with start-protect-vm.sh."
EOF

echo ""
echo ">>> Creating ISO..."
# hdiutil makehybrid refuses to overwrite; this script's job is to
# (re)generate the ISO, so clear any stale one first.
rm -f "$OUTPUT"
# The ISO now holds only short-named files, so plain ISO 9660 is fine.
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
echo "Then in the VM after Debian boots, as root:"
echo ""
echo "  mkdir -p /mnt/protect-on-mac"
echo "  mount /dev/sr0 /mnt/protect-on-mac"
echo "  bash /mnt/protect-on-mac/start-here.sh"
echo ""
echo "start-here.sh unpacks the project and runs the installers."
echo ""
echo "Inspect the bundle on macOS with:"
echo ""
echo "  hdiutil attach $OUTPUT"
echo "  tar tzf /Volumes/$(basename "$OUTPUT" .iso)/$TARBALL_NAME"
