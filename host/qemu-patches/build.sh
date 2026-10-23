#!/bin/bash
###############################################################################
# build.sh -- build qemu-system-aarch64 with this folder's macOS patches.
#
#   ./build.sh <version> [<sha256 of qemu-<version>.tar.xz>]
#
# Run it ON THE MAC THAT RUNS THE VM, so the binary links against that Mac's
# own Homebrew libraries (an MBP-built binary run on the mini can pick up
# mismatched dylibs). Needs the Xcode command-line tools plus Homebrew's
# meson, ninja and pkg-config, and Homebrew's qemu (for its build
# dependencies and its firmware files).
#
# Without a checksum argument the tarball is checked against the sha256
# Homebrew publishes for the same version, and refused if Homebrew is on a
# different version. The build is staged, never installed: the running VM is
# not touched. See README.md for the swap-in steps.
###############################################################################
set -euo pipefail
VER="${1:?usage: $0 <version> [sha256]}"
SUM="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${QEMU_BUILD_DIR:-$HOME/qemu-build}"
export PATH="/opt/homebrew/bin:$PATH"

for t in clang meson ninja pkg-config; do
    command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 1; }
done
if [ -z "$SUM" ]; then
    read -r bver SUM < <(brew info --json=v2 qemu | python3 -c '
import json, sys
f = json.load(sys.stdin)["formulae"][0]
print(f["versions"]["stable"], f["urls"]["stable"]["checksum"])')
    [ "$bver" = "$VER" ] || { echo "Homebrew has $bver, not $VER: pass the sha256 yourself" >&2; exit 1; }
fi

mkdir -p "$WORK" && cd "$WORK"
T="qemu-$VER.tar.xz"
[ -f "$T" ] || curl -sSfL --max-time 600 -o "$T" "https://download.qemu.org/$T"
echo "$SUM  $T" | shasum -a 256 -c -
rm -rf "qemu-$VER" && tar xf "$T" && cd "qemu-$VER"
for p in "$HERE"/0*.patch; do patch -p1 --no-backup-if-mismatch < "$p"; done

# --disable-pvg: Apple's paravirtualized-graphics device fails to link
# against the command-line-tools SDK on macOS 26 (_PGNewDeviceWithDescriptor),
# and the VM runs with -display none, so it is not needed.
./configure --target-list=aarch64-softmmu --enable-hvf --disable-docs \
    --disable-werror --disable-pvg
cd build && nice -n 10 ninja -j4
B="$PWD/qemu-system-aarch64"
"$B" --version | head -1
codesign -d --entitlements - "$B" 2>/dev/null | grep -q com.apple.security.hypervisor \
    || { echo "built binary lacks the hypervisor entitlement" >&2; exit 1; }
python3 "$HERE/test_qemu_enotty.py" "$B"
echo
echo "Built and tested: $B"
echo "Not installed. See $HERE/README.md to swap it in at a planned restart."
