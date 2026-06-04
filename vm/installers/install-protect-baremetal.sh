#!/bin/bash
###############################################################################
# install-protect-baremetal.sh
#
# Install UniFi Protect + Access on a fresh Debian 11 (Bullseye) ARM64 VM.
#
# This script extracts the Ubiquiti software from a UNVR firmware image,
# repacks the binaries as Debian packages, and installs them on top of a
# standard Debian system. The result is a VM that behaves like a UNVR for
# the purposes of running Protect and Access, but with the flexibility of
# a normal Linux machine for debugging, backup, and resource management.
#
# The approach is based on dciancu/unifi-protect-unvr-docker-arm64, which
# proved that the UNVR's user-space software can run outside the UNVR
# hardware. This script adapts that proof-of-concept into a baremetal
# install (no Docker), so the system runs as a real Linux host and can
# be managed with standard tools.
#
# WHY EACH PHASE EXISTS:
#   1. Base packages — establish the system dependencies expected by the
#      Ubiquiti binaries (Node.js, Python, Nginx, build tools, etc.)
#   2. PostgreSQL 14 — Protect and Access both require it; we install
#      Debian's standard packages.
#   3. Firmware download and extraction — pulls the UNVR firmware,
#      extracts the squashfs root, harvests the Ubiquiti packages.
#   4. Ubiquiti package install — installs the extracted .deb files via
#      apt-get with --allow-downgrades (some firmware packages are older
#      than what's in the Ubiquiti apt repo).
#   5. Protect + Access install — either uses the firmware-bundled version
#      or queries Ubiquiti's API for the latest stable/edge release.
#   6. unifi-core patch — the storage detection code calls a gRPC service
#      that doesn't exist on VMs; we patch it to use a simpler fallback.
#   7. Hardware spoofing — wrap ubnt-tools, ustorage, smartctl, uled-ctrl,
#      and mdadm with scripts that return sensible defaults for hardware
#      queries that have no answer on a VM.
#   8. Helper services — small systemd units that fix database paths,
#      hostname/etc-hosts issues, and storage disk detection.
#   9. Network setup — rename the primary NIC to enp0s2 if needed for
#      Ubiquiti cloud compatibility.
#  10. Storage directories — ensure /srv exists for the services. No
#      array is created; the user builds it from the web UI, exactly
#      like a real UNVR (provision-storage.sh handles it then).
#  11. Storage subsystem — the UNVR-faithful storage layer (dynamic
#      ustorage, ustated-shim, provision-storage, postgres-on-vda),
#      installed directly. The data disks are never touched.
#  12. Final cleanup and helper installation.
#
# PREREQUISITES:
#   - Fresh Debian 11 (Bullseye) ARM64 installation, SSH only
#   - Root access
#   - Internet connectivity during install
#   - At least 4GB RAM, 8GB recommended for production load
#   - One or more data disks for the recording array (created by the user
#     from the Protect web UI after install — see Phase 10)
#
# IMPORTANT WARNINGS:
#   - This is UNSUPPORTED by Ubiquiti. Use at your own risk.
#   - After initial console setup, DISABLE auto-update for both UniFi OS
#     and Protect in Console Settings. A firmware update can re-enable
#     services we've masked or introduce new ones that break the install.
#   - Test updates in a non-production VM first. The update-unifi.sh
#     script in this repo handles updates more safely than the web UI.
#
# Derived from dciancu/unifi-protect-unvr-docker-arm64 (MIT-licensed).
# Ubiquiti packages are proprietary — this script downloads them from
# official Ubiquiti sources, it does not redistribute them.
###############################################################################

# Strict mode:
#   -e: exit on any command failure
#   -u: treat unset variables as errors
#   -o pipefail: pipeline fails if any command in the pipe fails
# This catches bugs early instead of silently continuing past a broken step.
set -euo pipefail

# Where this script lives, resolved before any `cd`. Used to find sibling
# files in the vm/ tree (e.g. vm/wrappers/) when this runs from
# vm/installers/. Empty-safe: if the tree isn't laid out as expected the
# dependent steps check for the files and skip gracefully.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_TREE="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo "")"

###############################################################################
# CONFIGURATION — Edit these before running, or pass via environment
###############################################################################

# Device type identifier used internally by Ubiquiti code paths.
# UNVR is the standard NVR, UNVR_PRO has more bays, ENVR is the enterprise model.
DEVICE="${DEVICE:-UNVR}"

# Block device that will become /volume1 (the bulk storage for recordings).
# Must be a real device 150GB or larger (Protect's minimum is 128GB).
# On the first install this gets formatted; on migration it should be the
# existing UNVR data array assembled by mdadm (use mount-storage.sh import
# for the migration case instead of this script).
STORAGE_DISK="${STORAGE_DISK:-/dev/sda}"

# Postgres storage is no longer a config knob. The protect/access database
# clusters run from vda (the OS disk — fast, NVMe-backed on the host) and
# are kept on the recording array at rest by postgres-vda.service (see the
# storage subsystem). There is no separate-disk migration step.

# Network interface name. Cloud remote access expects enp0s2 specifically.
# If your VM's primary NIC is named differently, the script will create a
# systemd-networkd rule to rename it.
PRIMARY_INTERFACE="${PRIMARY_INTERFACE:-enp0s2}"

# Protect / AI Feature Console version.
#
# Empty (the default) installs the latest stable release from Ubiquiti's
# release channel. That is the configuration this project's storage shims
# and wrappers are tested against — keep it that way.
#
# Set to 1 to install the older version bundled inside the firmware
# instead. That combination is NOT tested with this project's shims; use
# it only if you have a specific reason.
PROTECT_STABLE="${PROTECT_STABLE:-}"

# UNVR firmware. By default Phase 4 queries Ubiquiti's firmware API for
# the latest release (so this never goes stale). Set FW_URL to a specific
# .bin URL to override — e.g. to pin a known-tested version, or to install
# an older release. Leave it empty for "latest".
FW_URL="${FW_URL:-}"

# AI Feature Console deb for the firmware-bundled (PROTECT_STABLE) path
# only. Firmware Protect is 6.x and depends on the old ai-feature-console.
# The default latest-stable path does NOT use this — it resolves the AI
# feature package (name and all) from the downloaded Protect deb instead.
AIFC_STABLE_URL="${AIFC_STABLE_URL:-https://fw-download.ubnt.com/data/ai-feature-console/f3c8-uos-deb11-arm64-1.9.15-3316d322-b5da-4f44-84a3-e823dfef82be.deb}"

# Ubiquiti's firmware-update API. Same endpoint the UNVR queries for
# update notifications. The AI feature package has no fixed endpoint here:
# its product name comes from Protect's own dependency metadata (Phase 5).
FW_UPDATE_URL="https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-nvr&filter=eq~~channel~~release&filter=eq~~platform~~${DEVICE}"
PROTECT_UPDATE_URL="https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-protect&filter=eq~~channel~~release&filter=eq~~platform~~uos-deb11-arm64"

# Verbose output during installation
DEBUG="${DEBUG:-false}"

###############################################################################
# VALIDATION
###############################################################################

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

if [ "$(uname -m)" != "aarch64" ]; then
    echo "ERROR: This script must run on ARM64 (aarch64)"
    exit 1
fi

if ! grep -q "bullseye" /etc/os-release 2>/dev/null; then
    echo "WARNING: This script is designed for Debian 11 (Bullseye)"
    echo "Your OS may not be compatible. Continue? (y/N)"
    read -r response
    if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
        exit 1
    fi
fi

# Check storage disk exists
if [ ! -b "$STORAGE_DISK" ]; then
    echo "ERROR: Storage disk $STORAGE_DISK does not exist."
    echo "Add a 150GB+ SATA disk to the VM and set STORAGE_DISK accordingly."
    echo "Example: STORAGE_DISK=/dev/sda bash install-protect-baremetal.sh"
    exit 1
fi

# Check storage disk is at least 128GB
DISK_SIZE_BYTES=$(blockdev --getsize64 "$STORAGE_DISK" 2>/dev/null || echo 0)
DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1073741824))
if [ "$DISK_SIZE_GB" -lt 128 ]; then
    echo "ERROR: Storage disk $STORAGE_DISK is ${DISK_SIZE_GB}GB."
    echo "Protect requires at least 128GB (150GB+ recommended)."
    exit 1
fi

###############################################################################
# WORKING DIRECTORY
###############################################################################

WORKDIR="/opt/unvr-install"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

###############################################################################
# Firmware-API helper
#
# The Ubiquiti firmware API returns JSON; the installer needs one field from
# it — the download href. This used `jq`, but Debian's jq pins an exact
# libjq1 (= 1.6-2.1+deb11u1), and the UNVR firmware ships its OWN libjq1
# (1.6~ubnt) which Phase 5 installs. Those collide ("held broken packages").
# python3 is already a dependency, so the installer parses the JSON with it
# and never installs jq — no conflict to resolve.
###############################################################################
fw_api_href() {
    python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["_embedded"]["firmware"][0]["_links"]["data"]["href"] or "")
except Exception:
    print("")'
}

###############################################################################
# apt-get install with UNVR ~ubnt-conflict auto-recovery
#
# The UNVR firmware ships some libraries as its own `~ubnt` builds. Once one
# is installed, any Debian package with a strict version dependency on the
# same library becomes uninstallable and apt aborts with:
#     <pkg> : Depends: <lib> (= <ver>) but <ver>~ubnt is to be installed
# (jq -> libjq1 was the first case we hit.)
#
# Such a Debian package is ALREADY non-functional once the ~ubnt library
# wins — the Ubiquiti stack needs that library — so removing the package
# apt named loses nothing real. This wrapper runs `apt-get install`, and on
# exactly that failure pattern removes the named blocker and retries. Output
# is teed live so a long install still shows progress. Best-effort: every
# removal is logged, and any failure that is NOT this pattern is surfaced
# unchanged (the caller, under `set -e`, then aborts as before).
###############################################################################
apt_install() {
    local tmp rc pkg tries=0
    tmp="$(mktemp)"
    while : ; do
        # `if pipeline` suppresses `set -e` for the apt-get call so its exit
        # status can be inspected; PIPESTATUS[0] is apt-get's own status.
        if apt-get "$@" 2>&1 | tee "$tmp"; then
            rm -f "$tmp"
            return 0
        fi
        rc=${PIPESTATUS[0]}
        pkg="$(grep -oE '^[[:space:]]*[a-zA-Z0-9.+-]+ : Depends:.*but [^ ]*~ubnt' "$tmp" \
               | head -1 | awk '{print $1}' || true)"
        if [ -z "$pkg" ] || [ "$tries" -ge 5 ]; then
            rm -f "$tmp"
            return "$rc"
        fi
        tries=$((tries + 1))
        echo ">>> apt_install: '$pkg' conflicts with a UNVR ~ubnt library —"
        echo "                 removing it (unusable once that library is in)"
        echo "                 and retrying the install."
        apt-get remove -y "$pkg" 2>/dev/null || true
    done
}

echo "=============================================="
echo "UniFi Protect Bare-Metal Installer (v2)"
echo "=============================================="
echo "Device:    $DEVICE"
echo "Storage:   $STORAGE_DISK (${DISK_SIZE_GB}GB)"
echo "Interface: $PRIMARY_INTERFACE"
echo "Protect:   $([ -n "$PROTECT_STABLE" ] && echo 'firmware-bundled' || echo 'latest stable')"
echo "Work dir:  $WORKDIR"
echo "=============================================="
echo ""

###############################################################################
# PHASE 0: Checkpoint the pristine VM
###############################################################################
#
# Right now the VM is a fresh Debian install with nothing on it. Ask the
# host — over the control channel — to take a "fresh-debian" snapshot, so
# a botched install can be rolled back to bare Debian with one command.
#
# protect-on-mac-ctl isn't installed yet (Phase 7 does that), so run it
# straight from the vm/ tree. Best-effort: if the control channel isn't
# configured the request fails and we just continue. The snapshot verb is
# idempotent, so re-running this installer won't clobber the original.

CTL_IN_TREE="$VM_TREE/wrappers/rootfs/usr/local/bin/protect-on-mac-ctl"
if [ -n "$VM_TREE" ] && [ -f "$CTL_IN_TREE" ]; then
    echo ">>> Phase 0: Requesting a fresh-debian snapshot via the control channel..."
    if bash "$CTL_IN_TREE" snapshot fresh-debian; then
        echo "    fresh-debian checkpoint is in place."
    else
        echo "    NOTE: could not take a fresh-debian snapshot (control channel"
        echo "          unavailable). Continuing — consider snapshotting manually."
    fi
else
    echo ">>> Phase 0: control channel client not found in the vm/ tree —"
    echo "    skipping the fresh-debian snapshot."
fi

###############################################################################
# PHASE 1: Install base system packages
###############################################################################

echo ">>> Phase 1: Installing base system packages..."

# Self-heal a dpkg/apt state left half-finished by an interrupted earlier
# run (e.g. an SSH drop mid-install). dpkg refuses every later apt-get call
# until the interrupted package is configured; apt-get -f install settles
# any dependency left dangling. Both are no-ops on a clean system.
dpkg --configure -a || true
apt-get -f install -y || true

# Debian's jq pins an exact libjq1 (= 1.6-2.1+deb11u1); the UNVR firmware
# ships its own libjq1 (1.6~ubnt). Once the firmware's libjq1 is on the
# system — e.g. from a prior partial run — Debian jq becomes uninstallable
# and blocks apt entirely. The installer no longer uses jq (it parses the
# firmware API JSON with python3), so drop any Debian jq up front; this is
# a no-op on a system that never had it.
apt-get remove -y jq 2>/dev/null || true

apt-get update
apt-get install -y apt-transport-https ca-certificates

# Switch to HTTPS sources
sed -i 's/http:/https:/g' /etc/apt/sources.list 2>/dev/null || true

apt-get update
apt-get -y upgrade
apt-get -y dist-upgrade
apt-get --purge autoremove -y

apt_install --no-install-recommends -y install \
    vim \
    adduser \
    inotify-tools \
    curl \
    wget \
    mount \
    psmisc \
    dpkg \
    apt \
    lsb-release \
    sudo \
    gnupg \
    apt-transport-https \
    ca-certificates \
    dirmngr \
    mdadm \
    iproute2 \
    ethtool \
    procps \
    cron \
    lvm2 \
    systemd \
    systemd-timesyncd \
    sysstat \
    net-tools \
    squashfs-tools \
    python3-pip \
    dpkg-repack

# Install binwalk 2.x from source (the Debian repo version is too old).
#
# Do NOT `pip3 install binwalk` from PyPI: that now resolves to binwalk
# 2.4.x, whose sdist is broken — it ships only binwalk/__init__.py and
# omits every submodule, so `binwalk -e` later dies with
# "ModuleNotFoundError: No module named 'binwalk.core'". The last good
# Python release is the v2.3.4 GitHub tag (the repo's default branch is
# now the unrelated Rust rewrite, binwalk 3).
BINWALK_TAG=v2.3.4
binwalk_tmp=$(mktemp -d)
wget --no-verbose -O "$binwalk_tmp/binwalk.tar.gz" \
    "https://github.com/ReFirmLabs/binwalk/archive/refs/tags/${BINWALK_TAG}.tar.gz"
tar -xzf "$binwalk_tmp/binwalk.tar.gz" -C "$binwalk_tmp"
binwalk_src=$(find "$binwalk_tmp" -maxdepth 1 -type d -name 'binwalk-*' | head -1)
pip3 install "$binwalk_src" --break-system-packages 2>/dev/null \
    || pip3 install "$binwalk_src"
rm -rf "$binwalk_tmp"
binwalk --help >/dev/null 2>&1 \
    || { echo "ERROR: binwalk install failed — 'binwalk --help' does not run" >&2; exit 1; }

# Save real mdadm binary before anything overwrites it
cp /sbin/mdadm /sbin/mdadm.real

echo ">>> Phase 1 complete."

###############################################################################
# PHASE 2: Install nginx from official repo
###############################################################################

echo ">>> Phase 2: Installing nginx..."

curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
    | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/debian $(lsb_release -cs) nginx" \
    | tee /etc/apt/sources.list.d/nginx.list

printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
    | tee /etc/apt/preferences.d/99nginx

echo ">>> Phase 2 complete."

###############################################################################
# PHASE 3: Install PostgreSQL 14
###############################################################################

echo ">>> Phase 3: Installing PostgreSQL 14..."

curl -sL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor \
    | tee /etc/apt/trusted.gpg.d/apt.postgresql.org.gpg >/dev/null

echo "deb https://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/postgresql.list

apt-get update
apt-get --no-install-recommends -y install postgresql-14

echo ">>> Phase 3 complete."

###############################################################################
# PHASE 4: Download and extract UNVR firmware
###############################################################################

echo ">>> Phase 4: Downloading and extracting UNVR firmware..."

mkdir -p "$WORKDIR/firmware-build"
cd "$WORKDIR/firmware-build"

if [ ! -f fwupdate.bin ]; then
    # Resolve the firmware URL. FW_URL set in the environment wins (lets
    # you pin a specific release); otherwise ask Ubiquiti's firmware API
    # for the latest UNVR release so this never goes stale.
    if [ -z "$FW_URL" ]; then
        echo "    Querying Ubiquiti for the latest UNVR firmware..."
        FW_URL="$(wget -q --output-document - "$FW_UPDATE_URL" \
            | fw_api_href)"
        if [ -z "$FW_URL" ] || [ "$FW_URL" = "null" ]; then
            echo "ERROR: could not determine the latest firmware URL from:" >&2
            echo "  $FW_UPDATE_URL" >&2
            echo "Set FW_URL to a .bin URL by hand and re-run." >&2
            exit 1
        fi
    fi
    echo "    Downloading firmware from:"
    echo "      $FW_URL"
    wget --no-verbose --show-progress --progress=dot:giga -O fwupdate.bin "$FW_URL"
fi

# Clean any previous extraction attempts
rm -rf _fwupdate.bin*extracted squashfs-root

echo "    Extracting firmware (this takes a while)..."
# --run-as=root: binwalk 2.3.x refuses to run its extraction utilities
# when invoked as root unless this is given explicitly. The Protect VM
# is operated as root, so the flag is required here.
binwalk --run-as=root -e fwupdate.bin || true

# Find the squashfs root.
SQFS_ROOT=$(find . -name "squashfs-root" -type d | head -1)

# binwalk reliably *carves* the squashfs blob (a *.squashfs file) but its
# automatic unsquashfs step is flaky — some runs leave only the carved
# image and no squashfs-root. When that happens, unpack the carved image
# ourselves; unsquashfs (squashfs-tools) handles the zstd-compressed UNVR
# squashfs directly.
if [ -z "$SQFS_ROOT" ]; then
    sqfs_img=$(find . -name '*.squashfs' -type f | head -1)
    if [ -n "$sqfs_img" ]; then
        echo "    binwalk left the squashfs unpacked — extracting $sqfs_img"
        unsquashfs -f -d "$(dirname "$sqfs_img")/squashfs-root" "$sqfs_img"
        SQFS_ROOT=$(find . -name "squashfs-root" -type d | head -1)
    fi
fi
if [ -z "$SQFS_ROOT" ]; then
    echo "ERROR: Could not find or extract squashfs-root from firmware" >&2
    echo "  binwalk produced no squashfs-root and carved no *.squashfs image." >&2
    echo "  Check that squashfs-tools is installed and fwupdate.bin is valid." >&2
    exit 1
fi

# Copy firmware version
cp "$SQFS_ROOT/usr/lib/version" "$WORKDIR/version"
cp "$WORKDIR/version" /usr/lib/version

# Extract Ubiquiti packages
echo "    Extracting Ubiquiti .deb packages..."
dpkg-query --admindir="$SQFS_ROOT/var/lib/dpkg/" -W -f='${package} | ${Maintainer}\n' | \
    grep -E '@ubnt.com|@ui.com' | cut -d '|' -f 1 > "$WORKDIR/packages.txt"

echo "    Packages found:"
cat "$WORKDIR/packages.txt"

mkdir -p "$WORKDIR/debs"
cd "$WORKDIR/debs"

while read pkg; do
    echo "    Repacking: $pkg"
    dpkg-repack --root="$WORKDIR/firmware-build/$SQFS_ROOT" --arch=arm64 "$pkg" 2>/dev/null || \
        echo "    WARNING: Failed to repack $pkg (may not be needed)"
done < "$WORKDIR/packages.txt"

# Remove the UNVR kernel package — we use the VM's kernel, not the UNVR's.
# This package fails to install (no UNVR bootloader) and blocks the entire install.
rm -f "$WORKDIR/debs/linux-image-"*.deb

# Remove the UNVR initramfs package — it adds boot scripts that wait for
# UNVR-specific hardware (MTD flash, eMMC) and break boot on VMs.
rm -f "$WORKDIR/debs/unvr-initramfs"*.deb

# Save the protect deb separately, then drop it from debs/. The firmware
# squashfs carries an old unifi-protect (e.g. 6.2.88) — keeping it in
# debs/ means the later `./*.deb` glob hands it to apt, which then prefers
# it over /opt/unifi-protect.deb and pulls its stale ai-feature-console
# dependency. Only the firmware-bundled install path wants this deb, and
# that path installs it explicitly from unifi-protect-deb/.
mkdir -p "$WORKDIR/unifi-protect-deb"
cp unifi-protect_*.deb "$WORKDIR/unifi-protect-deb/" 2>/dev/null || true
rm -f unifi-protect_*.deb

echo ">>> Phase 4 complete."

###############################################################################
# PHASE 5: Install Ubiquiti packages
###############################################################################

echo ">>> Phase 5: Installing Ubiquiti packages..."

cd "$WORKDIR/debs"

# Enable time sync
systemctl enable systemd-timesyncd.service 2>/dev/null || true
systemctl enable systemd-time-wait-sync.service 2>/dev/null || true

# Install keyring first
apt-get --no-install-recommends -y --allow-downgrades install ./ubnt-archive-keyring_*_arm64.deb

# Add Ubiquiti apt repo. A prior (interrupted) run may have installed
# fix_apt_ubiquiti_sources.sh, whose unit locks this file `chattr +i` so a
# firmware update can't drop the repo. On a re-run that immutable flag makes
# a plain `>` write fail with EPERM — clear it first (no-op if not set).
chattr -i /etc/apt/sources.list.d/ubiquiti.list 2>/dev/null || true
echo "deb https://apt.artifacts.ui.com $(lsb_release -cs) main release" \
    > /etc/apt/sources.list.d/ubiquiti.list
apt-get update

# Install uos-discovery-client with systemctl temporarily disabled
# (it tries to start services during install)
mv /bin/systemctl /bin/systemctl.tmp
echo -e '#!/bin/bash\necho 0' > /bin/systemctl
chmod +x /bin/systemctl
apt-get --no-install-recommends -y --allow-downgrades install ./uos-discovery-client_*_arm64.deb 2>/dev/null || true
mv /bin/systemctl.tmp /bin/systemctl
systemctl enable uos-discovery-client.service 2>/dev/null || true

# Install shared libs needed by media server (ms package)
apt-get --no-install-recommends -y --allow-downgrades install \
    libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 libglib2.0-0

if [ -n "${PROTECT_STABLE:-}" ]; then
    # Firmware-bundled: use the Protect deb extracted from the firmware
    # plus the pinned AI Feature Console. Not tested with this project's
    # shims — see the PROTECT_STABLE note in CONFIGURATION.
    echo "    Installing the firmware-bundled Protect..."
    wget --no-verbose --show-progress --progress=dot:giga \
        -O /opt/ai-feature-console.deb "$AIFC_STABLE_URL"

    apt_install -y --allow-downgrades --no-install-recommends \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        install ./*.deb /opt/ai-feature-console.deb "$WORKDIR/unifi-protect-deb/"*.deb

    rm /opt/ai-feature-console.deb
else
    # Latest stable: fetch the current Protect, then resolve ITS AI
    # feature dependencies from the deb's own metadata. Protect 7.x
    # depends on BOTH ai-feature-console and ai-feature-controller, each
    # pinned to an exact version; reading the full set from the deb means
    # an added/removed/renamed AI package needs no code change. The
    # firmware-bundled (PROTECT_STABLE) branch above keeps only the old
    # ai-feature-console, since firmware Protect is 6.x.
    echo "    Fetching the latest stable Protect..."
    PROTECT_URL="$(wget -q --output-document - "$PROTECT_UPDATE_URL" | fw_api_href)"
    echo "    Protect URL:"
    echo "      $PROTECT_URL"
    wget --no-verbose --show-progress --progress=dot:giga -O /opt/unifi-protect.deb "$PROTECT_URL"

    # Parse every ai-feature-* package from the Protect deb's Depends.
    AI_PKGS=()
    while read -r p; do
        [ -n "$p" ] && AI_PKGS+=("$p")
    done < <(dpkg-deb -f /opt/unifi-protect.deb Depends 2>/dev/null \
        | tr ',' '\n' | grep -oE 'ai-feature-[a-z0-9-]+' | sort -u)
    if [ "${#AI_PKGS[@]}" -eq 0 ]; then
        echo "ERROR: could not read Protect's ai-feature dependencies" >&2
        exit 1
    fi
    echo "    Protect's AI feature packages: ${AI_PKGS[*]}"

    # Query the firmware API for each, download to /opt.
    AI_DEBS=()
    for AI_PKG in "${AI_PKGS[@]}"; do
        AI_API="https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~${AI_PKG}&filter=eq~~channel~~release&filter=eq~~platform~~uos-deb11-arm64"
        AI_URL="$(wget -q --output-document - "$AI_API" | fw_api_href)"
        if [ -z "$AI_URL" ] || [ "$AI_URL" = "null" ]; then
            echo "ERROR: firmware API has no product '$AI_PKG'" >&2
            exit 1
        fi
        echo "    $AI_PKG:"
        echo "      $AI_URL"
        wget --no-verbose --show-progress --progress=dot:giga \
            -O "/opt/${AI_PKG}.deb" "$AI_URL"
        AI_DEBS+=("/opt/${AI_PKG}.deb")
    done

    apt_install -y --allow-downgrades --no-install-recommends \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        install ./*.deb "${AI_DEBS[@]}" /opt/unifi-protect.deb

    rm /opt/unifi-protect.deb "${AI_DEBS[@]}"
fi

# Install Access (optional, but most users want it).
#
# coturn (an Access dependency) asks an "install as service?" debconf
# question in its postinst. If unanswered, dpkg blocks forever — and not
# just here: a later Access (re)install from the web UI runs apt WITHOUT a
# noninteractive frontend, so it would hang on the same prompt. Setting the
# answer is not enough on its own — an interactive frontend re-asks a
# question it considers unanswered. Marking the question 'seen' is what
# makes EVERY frontend skip it, permanently, for this VM.
echo ""
echo "    Installing UniFi Access..."
echo "coturn coturn/install-as-service boolean false" | debconf-set-selections
printf 'SET coturn/install-as-service false\nFSET coturn/install-as-service seen true\n' \
    | debconf-communicate coturn 2>/dev/null || true

DEBIAN_FRONTEND=noninteractive apt_install install -y --allow-downgrades --no-install-recommends \
    -o Dpkg::Options::='--force-confdef' \
    -o Dpkg::Options::='--force-confold' \
    unifi-access unifi-face-shared-lib unifi-user-assets || \
    echo "    WARNING: Access install failed. Install via web UI after setup."

echo ">>> Phase 5 complete."

###############################################################################
# PHASE 6: Patch unifi-core for ustorage support
###############################################################################

echo ">>> Phase 6: Patching unifi-core for ustorage..."

# Patch unifi-core's service.js for storage detection — without it, the
# Storage Manager shows "No drives found". The site is a minified
#   return <fn>()?s.push(...)
# which we force to always push: `return <fn>(),!0?s.push(...)`. The
# minified function name changes with every firmware build (Qe -> at ->
# ...), so the pattern captures the identifier generically instead of
# hardcoding it — one `return X()?s.push` exists in the bundle. Idempotent:
# the replaced form `(),!0?s.push` no longer matches the pattern.
SVC=/usr/share/unifi-core/app/service.js
sed -i 's/\(return [A-Za-z_$][A-Za-z0-9_$]*()\)?s\.push/\1,!0?s.push/' "$SVC"
if grep -qF ',!0?s.push' "$SVC"; then
    echo "    storage-detection patch applied"
else
    echo "WARNING: storage-detection patch did not match — service.js may"
    echo "have changed shape; storage detection may not work. Check $SVC"
    echo "for a 'return <fn>()?s.push' site and patch it by hand."
fi

echo ">>> Phase 6 complete."

###############################################################################
# PHASE 7: Install hardware spoofing scripts
###############################################################################

echo ">>> Phase 7: Installing hardware spoofing scripts..."

# NOTE: We do NOT replace /sbin/mdadm with a fake. We keep the real mdadm
# binary because usd needs real RAID info. The real binary was saved as
# /sbin/mdadm.real in Phase 1.

# Hardware shims (ubnt-tools, ustorage, uled-ctrl, smartctl) live in the
# sibling install-shims.sh. update-unifi.sh --sync-os reinstalls the real
# UNVR binaries from the firmware squashfs and must re-apply the very same
# shims, so there is one definition both callers share.
STORAGE_DISK="$STORAGE_DISK" DEVICE="$DEVICE" \
    bash "$SCRIPT_DIR/install-shims.sh"

# --- /usr/local/bin/protect-on-mac-ctl (host<->guest control channel client) ---
# Always installed: update-unifi.sh uses it for pre-update snapshots, and
# the smartctl proxy (below) rides it too. Harmless if the channel isn't
# configured — the client just reports the channel unavailable.
if [ -n "$VM_TREE" ] && [ -f "$VM_TREE/wrappers/rootfs/usr/local/bin/protect-on-mac-ctl" ]; then
    install -m 0755 "$VM_TREE/wrappers/rootfs/usr/local/bin/protect-on-mac-ctl" \
        /usr/local/bin/protect-on-mac-ctl
    echo "    installed /usr/local/bin/protect-on-mac-ctl (control channel client)"
else
    echo "    NOTE: protect-on-mac-ctl not found in the vm/ tree — control channel"
    echo "          client not installed (snapshot triggers will be unavailable)"
fi

# --- protect-installed checkpoint one-shot ---
# Bookend to the Phase 0 fresh-debian snapshot: a systemd one-shot that
# snapshots the VM the first time Protect comes up healthy, then disables
# itself. Optional and best-effort — if either file is missing from the
# vm/ tree, skip the whole thing rather than aborting the install.
sv_script="$VM_TREE/wrappers/rootfs/usr/local/sbin/protect-installed-snapshot"
sv_unit="$VM_TREE/wrappers/rootfs/etc/systemd/system/protect-installed-snapshot.service"
if [ -n "$VM_TREE" ] && [ -f "$sv_script" ] && [ -f "$sv_unit" ]; then
    install -m 0755 "$sv_script" /usr/local/sbin/protect-installed-snapshot
    install -m 0644 "$sv_unit" \
        /etc/systemd/system/protect-installed-snapshot.service
    systemctl enable protect-installed-snapshot.service >/dev/null 2>&1 || true
    echo "    installed protect-installed snapshot one-shot"
    echo "    (runs once on first healthy boot, then self-disables)"
else
    echo "    NOTE: protect-installed-snapshot files not in the vm/ tree —"
    echo "          one-shot checkpoint not installed (non-fatal)"
fi

echo ">>> Phase 7 complete."

###############################################################################
# PHASE 8: Install helper services and scripts
###############################################################################

echo ">>> Phase 8: Installing helper services..."

# --- patch_db.sh (PostgreSQL setup) ---
cat > /usr/bin/patch_db.sh << 'PATCHDBEOF'
#!/bin/bash
mkdir -p /data/postgresql/14/main/{data,conf}

if [[ -d /etc/postgresql/14/main ]]; then
  echo "Found /etc/postgresql/14/main dir. Moving everything to /data/postgresql/14/main/conf"
  mv /etc/postgresql/14/main/* /data/postgresql/14/main/conf
  rm -rf /etc/postgresql/14/main
  ln -s /data/postgresql/14/main/conf /etc/postgresql/14/main
fi

sed -i -e 's/host    all             all             127.0.0.1\/32            scram-sha-256/host    all             all             127.0.0.1\/32            trust/g' /etc/postgresql/14/main/pg_hba.conf
sed -i -e 's/\/var\/lib\/postgresql\/14\/main/\/data\/postgresql\/14\/main\/data/g' /etc/postgresql/14/main/postgresql.conf

chown -R postgres:postgres /data/postgresql
chown -R postgres:postgres /srv/postgresql 2>/dev/null || true
chown -R postgres:postgres /etc/postgresql
PATCHDBEOF
chmod +x /usr/bin/patch_db.sh

# --- fix_hosts.sh ---
cat > /usr/sbin/fix_hosts.sh << 'FIXHOSTSEOF'
#!/usr/bin/env bash
set -euo pipefail
while inotifywait -e close_write /etc/hostname &> /dev/null; do
    HOSTS="$(cat /etc/hosts)"
    HOSTNAME="$(tr -d '\n' < /etc/hostname)"
    if ! grep -q "^127\.0\.1\.1 ${HOSTNAME}" <<< "$HOSTS"; then
        echo -n "$(sed "s/^127\.0\.1\.1.\+/127.0.1.1 ${HOSTNAME}/" <<< "$HOSTS")" > /etc/hosts
    fi
    unset HOSTS HOSTNAME
done
FIXHOSTSEOF
chmod +x /usr/sbin/fix_hosts.sh

# --- fix_apt_ubiquiti_sources.sh ---
# Ubiquiti package postinst scripts wipe the apt source the installer
# added (a real UNVR manages its own apt config). Recreate it so
# update-unifi.sh can still resolve ms/msr/msp/mst/ds/ubnt-opencv4-libs/
# etc. from apt.artifacts.ui.com — those are NOT in the firmware — then
# lock it immutable so it survives. Best-effort: never fails the unit.
cat > /usr/sbin/fix_apt_ubiquiti_sources.sh << 'FIXAPTEOF'
#!/usr/bin/env bash
codename="bullseye"
[ -r /etc/os-release ] && codename="$(. /etc/os-release; \
    echo "${VERSION_CODENAME:-bullseye}")"
f=/etc/apt/sources.list.d/ubiquiti.list
want="deb https://apt.artifacts.ui.com ${codename} main release"
if [ ! -f "$f" ] || [ "$(cat "$f" 2>/dev/null)" != "$want" ]; then
    chattr -i "$f" 2>/dev/null || true
    echo "$want" > "$f"
fi
chattr +i "$f" 2>/dev/null || true
exit 0
FIXAPTEOF
chmod +x /usr/sbin/fix_apt_ubiquiti_sources.sh

# --- storage_disk.sh ---
cat > /usr/sbin/storage_disk.sh << STORAGEDISKEOF
#!/bin/bash
disk="${STORAGE_DISK}"
echo "STORAGE_DISK=\${disk}" > /etc/default/storage_disk

echo "${DEVICE}" > /etc/default/device

debug="${DEBUG}"
if [[ "\$debug" == 'true' ]]; then
    cp -a /usr/share/unifi-core/app/config/default.yaml /usr/share/unifi-core/app/config/default.yaml.bak
    sed -Ei "s/defaultLevel: '.+'/defaultLevel: 'debug'/g" /usr/share/unifi-core/app/config/default.yaml
elif [ -f /usr/share/unifi-core/app/config/default.yaml.bak ]; then
    mv /usr/share/unifi-core/app/config/default.yaml.bak /usr/share/unifi-core/app/config/default.yaml
fi
STORAGEDISKEOF
chmod +x /usr/sbin/storage_disk.sh

# --- Systemd service: dbpermissions ---
cat > /etc/systemd/system/dbpermissions.service << 'DBPEOF'
[Unit]
Description=Set database permissions
Before=postgresql-cluster-14-main-upgrade.service postgresql-cluster-14-protect-upgrade.service
After=local-fs.target sysinit.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/bin/patch_db.sh

[Install]
WantedBy=postgresql-cluster-14-main-upgrade.service postgresql-cluster-14-protect-upgrade.service
DBPEOF

# --- Systemd service: fix_hosts ---
cat > /etc/systemd/system/fix_hosts.service << 'FHEOF'
[Unit]
Description=Fix hosts
Before=basic.target
After=local-fs.target sysinit.target
DefaultDependencies=no

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStart=/usr/sbin/fix_hosts.sh

[Install]
WantedBy=basic.target
FHEOF

# --- Systemd service: fix_apt_ubiquiti_sources ---
cat > /etc/systemd/system/fix_apt_ubiquiti_sources.service << 'FAEOF'
[Unit]
Description=Fix Ubiquiti APT sources
Before=basic.target
After=local-fs.target sysinit.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/sbin/fix_apt_ubiquiti_sources.sh

[Install]
WantedBy=basic.target
FAEOF

# --- Systemd service: storage_disk ---
cat > /etc/systemd/system/storage_disk.service << 'SDEOF'
[Unit]
Description=Save STORAGE_DISK env variable to file
Before=basic.target
After=local-fs.target sysinit.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/sbin/storage_disk.sh

[Install]
WantedBy=basic.target
SDEOF

# --- Systemd overrides for time services (needed in VMs) ---
mkdir -p /etc/systemd/system/systemd-time-wait-sync.service.d
cat > /etc/systemd/system/systemd-time-wait-sync.service.d/override.conf << 'TWEOF'
[Unit]
ConditionVirtualization=
ConditionCapability=
TWEOF

mkdir -p /etc/systemd/system/systemd-timesyncd.service.d
cat > /etc/systemd/system/systemd-timesyncd.service.d/override.conf << 'TSEOF'
[Unit]
ConditionVirtualization=
ConditionCapability=
TSEOF

# Enable all custom services
systemctl enable storage_disk dbpermissions fix_hosts fix_apt_ubiquiti_sources

# --- policy-rc.d to prevent services from auto-starting during apt ---
echo 'exit 0' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# --- Fix pg-cluster-upgrade script ---
[ -f /sbin/pg-cluster-upgrade ] && sed -i 's/rm -f/rm -rf/' /sbin/pg-cluster-upgrade

# --- Set sudoers permissions ---
chown root:root /etc/sudoers.d/* 2>/dev/null || true

# --- Fix PostgreSQL connection to use TCP ---
if [ -f /usr/lib/ulp-go/scripts/envs.sh ]; then
    echo -e '\n\nexport PGHOST=127.0.0.1\n' >> /usr/lib/ulp-go/scripts/envs.sh
fi

echo ">>> Phase 8 complete."

###############################################################################
# PHASE 9: Network interface setup
###############################################################################

echo ">>> Phase 9: Setting up network interfaces..."

# Create dummy enp0s1 interface
if ! ip link show enp0s1 &>/dev/null; then
    ip link add enp0s1 type dummy 2>/dev/null || true
fi

# Persist dummy interface via systemd-networkd
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/11-enp0s1.netdev << 'DUMMYEOF'
[NetDev]
Name=enp0s1
Kind=dummy
DUMMYEOF

# Rename primary interface to enp0s2 if needed for cloud remote access
CURRENT_MAC=$(ip link show $(ip route get 8.8.8.8 | grep -Po '(?<=(dev ))(\S+)') | awk '/ether/ {print $2}')
CURRENT_IFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=(dev ))(\S+)')

if [ "$CURRENT_IFACE" != "$PRIMARY_INTERFACE" ]; then
    echo "    Your primary interface is '$CURRENT_IFACE' (MAC: $CURRENT_MAC)"
    echo "    For cloud remote access, it needs to be named '$PRIMARY_INTERFACE'"
    echo ""
    echo "    Creating /etc/systemd/network/10-enp0s2.link"

    cat > /etc/systemd/network/10-enp0s2.link << LINKEOF
[Match]
MACAddress=${CURRENT_MAC}

[Link]
Name=${PRIMARY_INTERFACE}
LINKEOF

    echo "    Interface will be renamed to $PRIMARY_INTERFACE after reboot."
    echo "    UPDATE YOUR NETWORK CONFIG: replace '$CURRENT_IFACE'"
    echo "    with '$PRIMARY_INTERFACE' in /etc/network/interfaces."
fi

echo ">>> Phase 9 complete."

###############################################################################
# PHASE 10: Set up storage
###############################################################################

echo ">>> Phase 10: Preparing storage directories..."

# STORAGE ON A VM — WHY THIS PHASE NO LONGER BUILDS AN ARRAY
#
# A real UNVR ships with no storage array. `usd` does not auto-create
# one — the array is built only when the user commands it from the
# Protect web UI. Protect itself runs fine without an array: its own
# startup hook sets UFP_RECORDING_DISABLED when /srv is not a large
# mounted volume, so a fresh box comes up with recording disabled until
# storage is created.
#
# So this installer does NOT create or mount an array. It only ensures
# /srv exists as a plain directory on the OS disk, with the per-service
# subdirectories, so the services have a writable home on first boot.
# When the user later creates the array through the web UI, the storage
# subsystem (provision-storage.sh) builds it, migrates /srv's contents
# onto it, and replaces /srv with a symlink to /volume1/.srv — at which
# point Protect's hook re-evaluates and recording switches on.
#
# Importing disks from another UNVR is a separate path: mount-storage.sh.
#
# A dedicated postgres disk (the old POSTGRES_DISK install option) is no
# longer set up here. Postgres lives on the array at rest and is served
# from a vda working copy while running, via postgres-vda.service — no
# separate disk, and no migration step.

# Per-service data directories under /srv. Pre-created with the right
# ownership so a service does not end up with a root-owned data dir; the
# services would otherwise create these themselves on first start.
mkdir -p /srv/{unifi-protect,postgresql,unifi-core,ds,ms,uid,ulp-go,ai-feature-controller}
mkdir -p /srv/unifi-protect/{logs,backups}
chown -R unifi-protect:unifi-streaming /srv/unifi-protect /srv/ds /srv/ms \
    2>/dev/null || true
chown -R postgres:postgres /srv/postgresql 2>/dev/null || true

# WHY WE MASK INSTEAD OF DISABLE:
#
# The UNVR runs hardware-management services that crash on a VM because
# they expect physical hardware that doesn't exist (storage controllers,
# SFP+ ports, reset buttons, etc.). Disabling them isn't enough — they're
# triggered by `Wants=` or `Requires=` directives in other services like
# `ustated`, so systemd starts them anyway.
#
# Masking creates a symlink from the unit file to /dev/null, which makes
# systemd refuse to start the unit regardless of who asks for it. This
# survives package post-install scripts that try to re-enable services.
#
# Services we mask and why:
#   usd       UI Storage Daemon — manages physical disk topology. We replace
#             its functionality with a fake `/sbin/ustorage` script that
#             returns the size of /srv. Crashes hard on a VM because it
#             expects to manage real RAID hardware.
#   usdbd     usd's "broker" companion. Same reasoning.
#   rpsd      Reset Power Switch Daemon. Manages the UNVR's physical reset
#             button. No physical button on a VM.
#   uhwd      Hardware Watchdog Daemon. Monitors UNVR-specific hardware
#             health. Nothing to monitor on a VM.
#   sfp/sfpd  Small Form-factor Pluggable daemon. Manages the UNVR's SFP+
#             optical ports. VM doesn't have any.
for svc in usd usdbd rpsd uhwd sfp sfpd; do
    systemctl stop "${svc}.service" 2>/dev/null || true
    systemctl mask "${svc}.service" 2>/dev/null || true
done

echo ">>> Phase 10 complete."

###############################################################################
# PHASE 11: Create required directories and finalize
###############################################################################

echo ">>> Phase 11: Creating required directories..."

mkdir -p /data/unifi-core/logs
mkdir -p /data/unifi-core/config/http
touch /data/unifi-core/config/http/ssl-dynamic.conf
mkdir -p /data/postgresql/14/main/{data,conf}
mkdir -p /persistent
mkdir -p /var/log/ustd
mkdir -p /run/lock/ustd

# Set hostname
echo "UNVR" > /etc/hostname
hostname UNVR

# Ensure /etc/hosts has the hostname
if ! grep -q "127.0.1.1 UNVR" /etc/hosts; then
    echo "127.0.1.1 UNVR" >> /etc/hosts
fi

echo ">>> Phase 11 complete."

###############################################################################
# PHASE 12: Hold Ubiquiti packages
###############################################################################
#
# WHY WE DO THIS:
#
# The install adds Ubiquiti's apt repository (apt.artifacts.ui.com) so we
# can pull updates. But a plain `apt-get upgrade` would happily pull newer
# versions of every Ubiquiti package without the coordinated version
# handling that update-unifi.sh provides. The result: a `ds` newer than
# what `unifi-protect` expects, or vice versa — and Protect refuses to
# start.
#
# Holding the packages tells apt "don't touch these, even if updates are
# available." This makes `apt-get upgrade` safe by default for Debian-side
# updates (kernel, openssl, etc.) while leaving Ubiquiti package management
# to update-unifi.sh.
#
# The user will see a clear message when they run apt-get upgrade:
#
#   The following packages have been kept back:
#     ds  unifi-access  unifi-core  unifi-protect  ...
#
# That message is intentional — it tells them these are managed separately.
# To consciously override, they'd need `apt-mark unhold` or
# `--allow-change-held-packages`.

echo ">>> Phase 12: Holding Ubiquiti packages..."

# Packages managed by update-unifi.sh, not by apt-get upgrade. The set is
# derived from the package DB — every installed package whose Maintainer
# is a Ubiquiti address — rather than a hardcoded list. A newly added
# Ubiquiti package is then held automatically, with no list to maintain.
# update-unifi.sh derives the same set the same way (ubiquiti_packages()).
TO_HOLD=()
while read -r pkg; do
    [ -n "$pkg" ] && TO_HOLD+=("$pkg")
done < <(dpkg-query -W -f='${Package} ${Maintainer}\n' 2>/dev/null \
    | grep -E '@ubnt\.com|@ui\.com' \
    | awk '{print $1}')

if [ "${#TO_HOLD[@]}" -gt 0 ]; then
    apt-mark hold "${TO_HOLD[@]}"
    echo "    Held ${#TO_HOLD[@]} Ubiquiti packages."
    echo "    A plain 'apt-get upgrade' will skip these. Use update-unifi.sh"
    echo "    to update them, or 'apt-mark unhold <pkg>' to override."
fi

echo ">>> Phase 12 complete."

###############################################################################
# PHASE 13: Install the storage subsystem
###############################################################################
#
# The UNVR-faithful storage layer: the dynamic ustorage replacement (it
# supersedes the static fake Phase 7 installed), the ustated-shim,
# provision-storage (assembles the array at boot once the user creates it
# from the Protect web UI), the postgres-on-vda bind mount, and the
# unifi-core storage patch.
#
# These files live under ../storage/rootfs/, laid out at the exact paths
# they install to — the tree IS the manifest, so this phase just walks it
# and installs every file at its mirrored location. The standalone
# install-storage.sh installs the same tree the same way; it is kept for
# re-applying just this layer by hand after a component is edited.
#
# Nothing here touches the data disks. provision-storage only ASSEMBLES
# an array the user has already created from the web UI — on a box with
# no array yet it is a boot-time no-op, so any disks or images attached
# for /volume1 are left clean and untouched.

echo ">>> Phase 13: Installing the storage subsystem..."

STORAGE_ROOTFS="$SCRIPT_DIR/../storage/rootfs"
[ -d "$STORAGE_ROOTFS" ] \
    || { echo "ERROR: storage payload not found at $STORAGE_ROOTFS" >&2; exit 1; }

# Back up a non-shim ustorage before the walk overwrites it. After Phase 7
# this is usually the static fake; harmless to keep as the .orig.
if [ -e /usr/bin/ustorage ] \
   && ! head -3 /usr/bin/ustorage 2>/dev/null | grep -q 'ustorage-vm' \
   && [ ! -e /usr/bin/ustorage.orig ]; then
    cp -a /usr/bin/ustorage /usr/bin/ustorage.orig
fi

# Install every file at its mirrored path. Files under /etc/systemd/system
# are unit data (0644); everything else is an executable (0755). ._* are
# macOS AppleDouble files — skip them so no ._foo.service reaches systemd.
while IFS= read -r -d '' f; do
    rel="${f#"$STORAGE_ROOTFS"}"
    case "$rel" in
        /etc/systemd/system/*) mode=0644 ;;
        *)                     mode=0755 ;;
    esac
    install -D -m "$mode" "$f" "$rel"
    echo "    installed $rel"
done < <(find "$STORAGE_ROOTFS" -type f ! -name '._*' -print0)

# provision-on-setup.path watches /etc/ustd/storage.conf — ensure the dir.
mkdir -p /etc/ustd

# Free :11052 for the shim — ustated must not run.
systemctl mask usd ustated 2>/dev/null || true
systemctl stop usd ustated 2>/dev/null || true
systemctl daemon-reload

# Apply the unifi-core service.js patch now; its unit re-applies it on
# every boot, so it survives a package update replacing unifi-core.
/usr/local/bin/unifi-core-storage-patch.sh \
    || echo "    WARNING: storage patch returned non-zero — check it"

# Enable the boot-time units. storage-nuke is intentionally NOT enabled —
# it runs on demand only, triggered by the web UI "Erase" button.
# provision-on-setup.path provisions the array when the operator finishes
# the storage wizard (it watches /etc/ustd/storage.conf).
systemctl enable provision-storage.service \
                 postgres-vda.service \
                 ustated-shim.service \
                 unifi-core-storage-patch.service \
                 provision-on-setup.path >/dev/null
systemctl restart ustated-shim.service \
    || echo "    WARNING: ustated-shim did not start — check it"

echo ">>> Phase 13 complete."

###############################################################################
# CLEANUP
###############################################################################

echo ">>> Cleaning up..."

# Remove firmware build files to save space (keep the firmware binary for re-runs)
rm -rf "$WORKDIR/firmware-build/_fwupdate.bin"*extracted
rm -rf "$WORKDIR/debs"
rm -rf "$WORKDIR/unifi-protect-deb"

# Reload systemd
systemctl daemon-reload

echo ""
echo "=============================================="
echo "Installation complete!"
echo "=============================================="
echo ""
echo "The VM will reboot to bring up the renamed NIC, the"
echo "patched services and the storage shim, then it is ready"
echo "for first-boot setup in the web UI."
echo ""
echo "After the reboot, the console login prompt shows the"
echo "setup-portal URL (https://<this VM's IP>)."
echo ""
echo "AFTER first-boot setup: in Console Settings, DISABLE"
echo "auto-update for BOTH UniFi OS and Protect - a firmware"
echo "update can re-enable masked services and break the shims."
echo ""

# Console login banner. agetty expands \4 to the live IPv4 of the primary
# interface when it renders the prompt, so whoever lands on the VM console
# (or the QEMU serial console) is told exactly which URL to open.
cat > /etc/issue <<'ISSUEEOF'

  ============================================================
   UniFi Protect VM - ready for first-boot setup
   Open the setup portal in a browser:   https://\4
  ============================================================

ISSUEEOF

# Make the login prompt wait until the network is up. agetty's \4 escape
# uses getifaddrs() to find a non-loopback IPv4; if DHCP hasn't run yet it
# has nothing and falls back to gethostbyname(hostname), which resolves
# UNVR -> 127.0.1.1 via /etc/hosts. The operator then sees the banner once
# with a bogus 127.0.1.1, then again with the real IP after DHCP triggers
# a re-render. Pulling network-online.target into the getty units' startup
# makes the very first render happen with the correct IPv4 in place.
#
# Both the serial (-nographic / ttyAMA0) and virtual-terminal (tty1) getty
# units get the drop-in. ifupdown-wait-online.service enforces a timeout
# (~30s), so a host with no network never blocks the prompt indefinitely.
for _unit in serial-getty@ttyAMA0.service getty@tty1.service; do
    _dir="/etc/systemd/system/$_unit.d"
    mkdir -p "$_dir"
    cat > "$_dir/wait-network.conf" <<'DROPIN'
[Unit]
Wants=network-online.target
After=network-online.target
DROPIN
done
systemctl daemon-reload 2>/dev/null || true

# Auto-reboot after a 60s grace period. `read -t 60 -n1` waits up to 60s
# for a keypress: press any key to reboot immediately, Ctrl-C to cancel
# and reboot later, or just wait it out. Under `nohup` (no tty) the read
# returns at once and it reboots — an unattended install still lands at
# the login prompt on its own.
trap 'echo; echo "Reboot cancelled - finish with: systemctl reboot"; exit 0' INT
echo "Rebooting in 60 seconds."
echo "  Press any key to reboot now, or Ctrl-C to cancel and reboot later."
read -r -t 60 -n1 _ || true
trap - INT
echo
echo "Rebooting now..."
systemctl reboot
