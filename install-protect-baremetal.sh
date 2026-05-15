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
#  10. Storage setup — create or assemble the storage RAID, mount at
#      /volume1, symlink /srv. Optionally migrate postgres to a dedicated
#      SSD for dramatic UI performance improvement.
#  11. Final cleanup and helper installation.
#
# PREREQUISITES:
#   - Fresh Debian 11 (Bullseye) ARM64 installation, SSH only
#   - Root access
#   - Internet connectivity during install
#   - At least 4GB RAM, 8GB recommended for production load
#   - A second disk (150GB+) attached at $STORAGE_DISK for /volume1
#   - Optionally, a third disk for $POSTGRES_DISK (dramatically improves
#     UI responsiveness — see README for details)
#
# IMPORTANT WARNINGS:
#   - This is UNSUPPORTED by Ubiquiti. Use at your own risk.
#   - After initial console setup, DISABLE auto-update for both UniFi OS
#     and Protect in Console Settings. A firmware update can re-enable
#     services we've masked or introduce new ones that break the install.
#   - Test updates in a non-production VM first. The unifi-update.sh
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

# Optional dedicated disk for Postgres database storage.
# When set, postgres data is mounted at /srv/postgresql from this disk
# instead of living on the storage RAID. This dramatically improves UI
# responsiveness (face search goes from minutes to seconds) because the
# database stops competing with continuous camera writes for disk seeks.
# Leave empty to skip this optimization.
POSTGRES_DISK="${POSTGRES_DISK:-}"

# Network interface name. Cloud remote access expects enp0s2 specifically.
# If your VM's primary NIC is named differently, the script will create a
# systemd-networkd rule to rename it.
PRIMARY_INTERFACE="${PRIMARY_INTERFACE:-enp0s2}"

# Set to 1 to install the Protect version bundled with the firmware (older
# but battle-tested). Leave empty to install the latest from Ubiquiti's
# release channel (newer features but less proven).
PROTECT_STABLE="${PROTECT_STABLE:-1}"

# UNVR firmware URL. Defaults to a known-good version. Newer firmware may
# work but hasn't been tested with this script.
FW_URL="${FW_URL:-https://fw-download.ubnt.com/data/unifi-nvr/3488-UNVR-5.0.13-5fc20899-54b4-44a2-a958-f3b210adf9da.bin}"

# AI Feature Console deb. The firmware doesn't always include the latest
# AI FC, so we download it separately.
AIFC_STABLE_URL="${AIFC_STABLE_URL:-https://fw-download.ubnt.com/data/ai-feature-console/f3c8-uos-deb11-arm64-1.9.15-3316d322-b5da-4f44-84a3-e823dfef82be.deb}"

# Ubiquiti's firmware-update API. Same endpoint the UNVR queries for
# update notifications.
PROTECT_UPDATE_URL="https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-protect&filter=eq~~channel~~release&filter=eq~~platform~~uos-deb11-arm64"
AIFC_UPDATE_URL="https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~ai-feature-console&filter=eq~~channel~~release&filter=eq~~platform~~uos-deb11-arm64"

# Verbose output during installation
DEBUG="${DEBUG:-false}"

# Optional smartctl proxy. By default Phase 7 installs a static fake
# /usr/sbin/smartctl that always reports a healthy virtual disk. Set
# SMARTCTL_PROXY=1 to instead install the real smartmontools binary plus
# a wrapper that forwards SMART queries to the QEMU host, so Protect's UI
# can show real disk health for raw-passthrough disks. The wrapper falls
# back to the local real smartctl if the host is unreachable. Enabling
# this requires extra host-side setup — see the README "smartctl proxy"
# section. Leave empty to keep the fake.
SMARTCTL_PROXY="${SMARTCTL_PROXY:-}"

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

echo "=============================================="
echo "UniFi Protect Bare-Metal Installer (v2)"
echo "=============================================="
echo "Device:    $DEVICE"
echo "Storage:   $STORAGE_DISK (${DISK_SIZE_GB}GB)"
echo "Interface: $PRIMARY_INTERFACE"
echo "Stable:    ${PROTECT_STABLE:-no (edge)}"
echo "Work dir:  $WORKDIR"
echo "=============================================="
echo ""

###############################################################################
# PHASE 1: Install base system packages
###############################################################################

echo ">>> Phase 1: Installing base system packages..."

apt-get update
apt-get install -y apt-transport-https ca-certificates

# Switch to HTTPS sources
sed -i 's/http:/https:/g' /etc/apt/sources.list 2>/dev/null || true

apt-get update
apt-get -y upgrade
apt-get -y dist-upgrade
apt-get --purge autoremove -y

apt-get --no-install-recommends -y install \
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
    jq \
    squashfs-tools \
    python3-pip \
    dpkg-repack

# Install binwalk via pip (Debian repo version is too old, lacks features)
pip3 install binwalk --break-system-packages 2>/dev/null || pip3 install binwalk

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
    echo "    Downloading firmware from: $FW_URL"
    wget --no-verbose --show-progress --progress=dot:giga -O fwupdate.bin "$FW_URL"
fi

# Clean any previous extraction attempts
rm -rf _fwupdate.bin*extracted squashfs-root

echo "    Extracting firmware (this takes a while)..."
binwalk -e fwupdate.bin || true

# Find the squashfs root
SQFS_ROOT=$(find . -name "squashfs-root" -type d | head -1)
if [ -z "$SQFS_ROOT" ]; then
    echo "ERROR: Could not find squashfs-root in firmware extraction"
    echo "Make sure squashfs-tools is installed (apt install squashfs-tools)"
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

# Save the protect deb separately
mkdir -p "$WORKDIR/unifi-protect-deb"
cp unifi-protect_*.deb "$WORKDIR/unifi-protect-deb/" 2>/dev/null || true

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

# Add Ubiquiti apt repo
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
    # STABLE: Use Protect version from firmware + pinned AI Feature Console
    echo "    Installing STABLE Protect from firmware..."
    wget --no-verbose --show-progress --progress=dot:giga \
        -O /opt/ai-feature-console.deb "$AIFC_STABLE_URL"

    apt-get -y --allow-downgrades --no-install-recommends \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        install ./*.deb /opt/ai-feature-console.deb "$WORKDIR/unifi-protect-deb/"*.deb

    rm /opt/ai-feature-console.deb
else
    # EDGE: Fetch latest Protect and AI Feature Console
    echo "    Fetching latest EDGE Protect version..."
    PROTECT_URL="$(wget -q --output-document - "$PROTECT_UPDATE_URL" | jq -r '._embedded.firmware[0]._links.data.href')"
    AIFC_URL="$(wget -q --output-document - "$AIFC_UPDATE_URL" | jq -r '._embedded.firmware[0]._links.data.href')"

    echo "    Protect URL: $PROTECT_URL"
    echo "    AI FC URL:   $AIFC_URL"

    wget --no-verbose --show-progress --progress=dot:giga -O /opt/unifi-protect.deb "$PROTECT_URL"
    wget --no-verbose --show-progress --progress=dot:giga -O /opt/ai-feature-console.deb "$AIFC_URL"

    apt-get -y --allow-downgrades --no-install-recommends \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        install ./*.deb /opt/ai-feature-console.deb /opt/unifi-protect.deb

    rm /opt/unifi-protect.deb /opt/ai-feature-console.deb
fi

# Install Access (optional, but most users want it)
# Coturn config prompt has to be auto-answered or the install hangs
echo ""
echo "    Installing UniFi Access..."
echo "coturn coturn/install-as-service boolean false" | debconf-set-selections

DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades --no-install-recommends \
    -o Dpkg::Options::='--force-confdef' \
    -o Dpkg::Options::='--force-confold' \
    unifi-access unifi-face-shared-lib unifi-user-assets || \
    echo "    WARNING: Access install failed. Install via web UI after setup."

echo ">>> Phase 5 complete."

###############################################################################
# PHASE 6: Patch unifi-core for ustorage support
###############################################################################

echo ">>> Phase 6: Patching unifi-core for ustorage..."

# This sed patches unifi-core's service.js to use ustorage instead of gRPC ustate
# for storage detection. Without this, Storage Manager shows "No drives found".
# The pattern may change with firmware updates.
if ! sed -i '/return Qe()?s.push/{s//return Qe(),!0?s.push/;h};${x;/./{x;q0};x;q1}' \
    /usr/share/unifi-core/app/service.js; then
    echo "WARNING: sed patch failed - storage detection may not work."
    echo "Check /usr/share/unifi-core/app/service.js manually."
fi

echo ">>> Phase 6 complete."

###############################################################################
# PHASE 7: Install hardware spoofing scripts
###############################################################################

echo ">>> Phase 7: Installing hardware spoofing scripts..."

# Backup originals (ubnt-tools is from UNVR firmware, not a real binary)
[ -f /sbin/ubnt-tools ] && mv /sbin/ubnt-tools /sbin/ubnt-tools.orig

# NOTE: We do NOT replace /sbin/mdadm with a fake. We keep the real mdadm
# binary because usd needs real RAID info. The real binary was saved as
# /sbin/mdadm.real in Phase 1.

# --- /etc/default/storage_disk ---
# NOTE: No #!/bin/bash line — this is sourced as a config file
cat > /etc/default/storage_disk << STORAGEOF
STORAGE_DISK=${STORAGE_DISK}
STORAGEOF

# --- /etc/default/device ---
echo "$DEVICE" > /etc/default/device

# --- /sbin/ubnt-tools (fake board identity) ---
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

# --- /usr/bin/ustorage (fake storage inspection) ---
cat > /usr/bin/ustorage << 'USTOREOF'
#!/bin/bash

source /etc/default/storage_disk
disk="${STORAGE_DISK:-/dev/sda1}"
device=$(basename "${disk}")
sbytes=$(df -B1 --output=size /srv | awk 'NR==2 {print $1}')
sused=$(df -B1 --output=used /srv | awk 'NR==2 {print $1}')

case "${1:-}" in
    disk)
        if [ "${2:-}" = 'inspect' ]; then
            cat <<EOT
[
    {
        "action": "none",
        "ata": "ATA8-ACS",
        "bad_sector": 0,
        "error_log_count": 0,
        "estimate": null,
        "firmware": "AX001Q",
        "healthy": "good",
        "life_span": 100,
        "model": "UniFi Protect Storage",
        "poweronhrs": 1,
        "progress": null,
        "read_error": 0,
        "reason": null,
        "rpm": 5400,
        "sata": "SATA 3",
        "serial": "X0JNP396T",
        "size": ${sbytes},
        "slot": 1,
        "smart_error_count": 0,
        "state": "normal",
        "temperature": 49,
        "threshold": 10,
        "type": "HDD",
        "unc_count": 0
    }
]
EOT
        fi
    ;;
    space)
        if [ "${2:-}" = 'inspect' ]; then
            cat <<EOT
[
    {
        "action": "none",
        "device": "${device}",
        "errors_count": 0,
        "estimate": 0,
        "health": "health",
        "progress": null,
        "raid": null,
        "reasons": [],
        "resv_bytes": 0,
        "space_type": "primary",
        "total_bytes": ${sbytes},
        "used_bytes": ${sused}
    }
]
EOT
        fi
    ;;
    config)
        if [ "${2:-}" = 'show' ]; then
            cat <<EOT
{
    "hotspare": false,
    "raid": "raid1"
}
EOT
        fi
    ;;
    rwfs)
        if [ "${2:-}" = 'check' ]; then
            cat <<EOT
{
    "isMigrated": false,
    "migratable": {"canMigrate": false, "reason": "not-support"}
}
EOT
        fi
esac
USTOREOF
chmod +x /usr/bin/ustorage

if [ -n "${SMARTCTL_PROXY:-}" ]; then
# --- /usr/sbin/smartctl (proxy wrapper — forwards SMART to the host) ---
echo "    SMARTCTL_PROXY enabled — installing real smartmontools + proxy wrapper..."
apt-get --no-install-recommends -y install smartmontools openssh-client

# smartmontools ships smartd, which fails on a VM with no real disks.
systemctl disable --now smartd 2>/dev/null || true

# The package installs the real binary at /usr/sbin/smartctl. Move it
# aside so the wrapper can fall back to it when the host is unreachable.
if [ -f /usr/sbin/smartctl ] && [ ! -f /usr/sbin/smartctl.real ]; then
    mv /usr/sbin/smartctl /usr/sbin/smartctl.real
fi

# Proxy configuration. PROXY_HOST is intentionally left blank — the admin
# must set it to the Mac host's LAN IP. Until then the wrapper falls back
# to the local real smartctl.
cat > /etc/default/smartctl-proxy << 'PROXYCONF'
# Configuration for the smartctl proxy wrapper (/usr/sbin/smartctl).
# Sourced by the wrapper on every invocation.

# LAN IP (or hostname) of the Mac running the QEMU host. REQUIRED — the
# wrapper falls back to local SMART data while this is empty.
PROXY_HOST=

# macOS user the VM SSHes in as (the user that runs start-protect-vm.sh).
PROXY_USER=YOUR_MAC_USERNAME

# SSH private key the wrapper authenticates with. Generated by the
# installer; see /etc/protect-smartctl-proxy/.
PROXY_KEY=/etc/protect-smartctl-proxy/id_ed25519
PROXYCONF
chmod 600 /etc/default/smartctl-proxy

# Generate the SSH keypair the wrapper uses to reach the host. The public
# key gets added to the Mac's authorized_keys with a forced command —
# see the README "smartctl proxy" section.
mkdir -p /etc/protect-smartctl-proxy
chmod 700 /etc/protect-smartctl-proxy
if [ ! -f /etc/protect-smartctl-proxy/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N '' -C 'protect-smartctl-proxy' \
        -f /etc/protect-smartctl-proxy/id_ed25519
fi
chmod 600 /etc/protect-smartctl-proxy/id_ed25519
touch /etc/protect-smartctl-proxy/known_hosts
chmod 644 /etc/protect-smartctl-proxy/known_hosts

cat > /usr/sbin/smartctl << 'SMARTPROXYEOF'
#!/bin/bash
# smartctl proxy wrapper.
#
# Protect queries disk health by running smartctl against the VM's disks.
# Inside the VM those are virtio-scsi devices with no real SMART data, so
# this wrapper forwards the query to the QEMU host, which CAN read the
# physical disk over USB (with the kasbert SAT SMART kext installed).
#
# Flow: resolve the device argument's serial -> SSH to the host with a
# forced-command key, passing "serial + flags" -> host helper maps the
# serial to a /dev/diskN and runs real smartctl -> output comes back.
#
# Any failure (proxy not configured, host down, unknown disk, SSH error)
# falls through to the local real smartctl. The proxy is best-effort.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
REAL=/usr/sbin/smartctl.real
CONF=/etc/default/smartctl-proxy

fallback() { exec "$REAL" "$@"; }

[ -x "$REAL" ] || { echo "smartctl proxy: $REAL missing" >&2; exit 1; }
[ -r "$CONF" ] && . "$CONF"
[ -n "${PROXY_HOST:-}" ] && [ -n "${PROXY_USER:-}" ] && [ -r "${PROXY_KEY:-}" ] \
    || fallback "$@"

# Find the device argument (last token that looks like a device path).
dev=""
for a in "$@"; do
    case "$a" in /dev/*) dev="$a" ;; esac
done
[ -n "$dev" ] || fallback "$@"

# Resolve the device to its serial. Raw-passthrough disks carry the real
# ATA serial on their virtio-scsi device; that serial is the map key.
serial=$(lsblk -ndo SERIAL "$dev" 2>/dev/null | head -n1 | tr -d '[:space:]')
[ -n "$serial" ] || fallback "$@"

# Everything that isn't the device path is a flag to forward.
flags=()
for a in "$@"; do
    case "$a" in /dev/*) ;; *) flags+=("$a") ;; esac
done

# Ask the host. The forced command there receives "serial flags..." via
# SSH_ORIGINAL_COMMAND.
out=$(ssh -i "$PROXY_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/etc/protect-smartctl-proxy/known_hosts \
        "${PROXY_USER}@${PROXY_HOST}" -- "$serial" "${flags[@]}" 2>/dev/null)
rc=$?

if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
fi
fallback "$@"
SMARTPROXYEOF
chmod +x /usr/sbin/smartctl

else
# --- /usr/sbin/smartctl (fake SMART data) ---
cat > /usr/sbin/smartctl << 'SMARTEOF'
#!/bin/bash

source /etc/default/storage_disk
disk="${STORAGE_DISK:-/dev/sda1}"

if [ "${1:-}" = "$disk" ] || [ "${2:-}" = "$disk" ] || [ "${3:-}" = "$disk" ]; then
    cat <<EOT
smartctl 7.2 2020-12-30 r5155 [aarch64-linux] (local build)
Copyright (C) 2002-20, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF INFORMATION SECTION ===
Device Model:     Virtual Storage Device
Serial Number:    VM-PROTECT-001
Firmware Version: 1.00
User Capacity:    $(df -B1 --output=size /srv | awk 'NR==2 {print $1}') bytes
Sector Sizes:     512 bytes logical, 4096 bytes physical
Rotation Rate:    5400 rpm
Form Factor:      3.5 inches
SMART support is: Available - device has SMART capability.
SMART support is: Enabled

=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED
EOT
fi
SMARTEOF
chmod +x /usr/sbin/smartctl
fi

# --- /usr/bin/uled-ctrl (dummy LED controller) ---
touch /usr/bin/uled-ctrl
chmod +x /usr/bin/uled-ctrl

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
cat > /usr/sbin/fix_apt_ubiquiti_sources.sh << 'FIXAPTEOF'
#!/usr/bin/env bash
set -euo pipefail
chattr +i /etc/apt/sources.list.d/ubiquiti.list
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
    echo "    UPDATE YOUR NETWORK CONFIG to use '$PRIMARY_INTERFACE' instead of '$CURRENT_IFACE'"
fi

echo ">>> Phase 9 complete."

###############################################################################
# PHASE 10: Set up storage
###############################################################################

echo ">>> Phase 10: Setting up storage..."

# THE STORAGE PROBLEM ON A VM
#
# The real UNVR has a fixed storage topology: four SATA bays in hardware,
# /dev/md3 as a RAID5 across sda-sdd. Ubiquiti's `usd` (UI Storage Daemon)
# expects this exact arrangement and crashes if it doesn't find it.
#
# On a VM, we don't have that hardware. To make `usd` happy without rewriting
# its source code, we create a fake `/dev/md3` that looks like a real RAID
# but is actually just our storage disk wrapped in a single-disk RAID0.
# This satisfies the "is there a RAID at /dev/md3?" check without requiring
# multiple physical disks.
#
# For an actual migration from a UNVR, we don't create the array — the
# real RAID assembles from the imported disks. Use mount-storage.sh for
# that case. This script's md3 creation is for fresh installs only.

echo "    Creating /dev/md3 from $STORAGE_DISK..."
# We call mdadm.real (not mdadm) because Phase 7 installed a wrapper at
# /sbin/mdadm to intercept the "--detail /dev/md3" calls that unifi-core
# makes every minute. The wrapper would otherwise interfere with the
# actual array creation here.
/sbin/mdadm.real --create /dev/md3 --level=0 --raid-devices=1 --force "$STORAGE_DISK" <<< "y"

# Format the new array as ext4. This is the filesystem the UNVR uses.
echo "    Formatting /dev/md3..."
mkfs.ext4 -q /dev/md3

# Mount at /volume1. This is the UNVR's standard data mount point — Protect
# and Access look for /srv (a symlink we'll create next) which on the UNVR
# points to a directory on /volume1.
mkdir -p /volume1
mount /dev/md3 /volume1

# Get the UUID for fstab. We mount by UUID instead of /dev/md3 because:
#  1. When you import disks from another UNVR (the migration case), the
#     array assembles with the original UNVR's hostname embedded in the
#     mdadm superblock, which makes Linux name it /dev/md126 or /dev/md127
#     instead of /dev/md3. The UUID is stable regardless.
#  2. UUID-based mounts survive any future device renumbering.
STORAGE_UUID=$(blkid -s UUID -o value /dev/md3)
echo "    Storage UUID: $STORAGE_UUID"

# Create the directory structure Ubiquiti's software expects. The UNVR
# stores everything under /srv/.srv/<service> in a way that's hidden from
# the user via the /srv symlink — we replicate that here. Each service
# gets its own subdirectory.
mkdir -p /volume1/.srv/{unifi-protect,postgresql,unifi-core,ds,ms,uid,ulp-go,ai-feature-console}
mkdir -p /volume1/.srv/unifi-protect/{logs,backups}

# This marker file tells unifi-core that the database cluster has been
# migrated to its final location. Without it, unifi-core may try to
# re-migrate on every startup.
touch /volume1/.srv/.db-cluster-migrated.ctl

# Set ownership so each service can write to its directory. Without
# correct ownership, services fail with permission errors at startup.
chown -R unifi-protect:unifi-streaming /volume1/.srv/unifi-protect 2>/dev/null || true
chown -R unifi-protect:unifi-streaming /volume1/.srv/ds 2>/dev/null || true
chown -R unifi-protect:unifi-streaming /volume1/.srv/ms 2>/dev/null || true
chown -R postgres:postgres /volume1/.srv/postgresql 2>/dev/null || true

# Replace /srv with a symlink to /volume1/.srv.
#
# The UNVR firmware ships /srv as a directory but writes nothing to it —
# everything that looks like it's in /srv is actually in /volume1/.srv,
# accessed through this symlink. We replicate the structure exactly so
# Ubiquiti software finds its data where it expects.
#
# This also means storage size reporting works: when something checks
# the size of /srv, it gets the size of /volume1, which on the real UNVR
# is the size of the storage RAID.
rm -rf /srv
ln -s /volume1/.srv /srv

# Save the array config so mdadm assembles it correctly on next boot.
mdadm --detail --scan >> /etc/mdadm/mdadm.conf

# Persist the mount via UUID. The nofail option prevents boot failure if
# the storage isn't available (helpful for debugging — if the DAS isn't
# connected, the VM still boots and we can investigate).
echo "UUID=$STORAGE_UUID /volume1 ext4 defaults,nofail 0 2" >> /etc/fstab

# OPTIONAL: Dedicated postgres disk for dramatic UI speedup.
#
# Why this matters: Protect's UI responsiveness is bounded by postgres
# query speed. Face recognition search, timeline scrubbing, smart detection
# event lookups — all of these are postgres queries. When postgres lives
# on the same spinning RAID as camera recordings, every query waits for
# the disks to seek between continuous write operations (28 cameras at
# 200Mbps sustained = constant disk activity).
#
# Moving postgres to a dedicated SSD takes face search from 4 minutes to
# under 2 seconds. The database working set is small (3-4GB) but the I/O
# pattern (scattered small reads) is exactly what spinning disks handle
# worst.
#
# Set POSTGRES_DISK in the environment to enable this. We mount the SSD
# at /volume1/.srv/postgresql (which is also /srv/postgresql via the
# symlink), so postgres writes go to fast storage but everything else
# (recordings, configurations) stays on the bulk RAID.
if [ -n "${POSTGRES_DISK:-}" ]; then
    echo ""
    echo "    Setting up dedicated postgres disk: $POSTGRES_DISK"
    if [ ! -b "$POSTGRES_DISK" ]; then
        echo "    WARNING: $POSTGRES_DISK not found, skipping postgres disk setup"
    else
        # Label the filesystem so we can mount by LABEL rather than UUID
        # (LABEL is easier to track than a UUID for an admin reading fstab).
        mkfs.ext4 -q -L pgdata "$POSTGRES_DISK"
        echo "LABEL=pgdata /volume1/.srv/postgresql ext4 defaults,nofail 0 2" >> /etc/fstab
        mount /volume1/.srv/postgresql
        chown postgres:postgres /volume1/.srv/postgresql
        echo "    Postgres data will live on $POSTGRES_DISK (mounted at /srv/postgresql)"
    fi
fi

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
# handling that unifi-update.sh provides. The result: a `ds` newer than
# what `unifi-protect` expects, or vice versa — and Protect refuses to
# start.
#
# Holding the packages tells apt "don't touch these, even if updates are
# available." This makes `apt-get upgrade` safe by default for Debian-side
# updates (kernel, openssl, etc.) while leaving Ubiquiti package management
# to unifi-update.sh.
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

# Packages managed by unifi-update.sh, not by apt-get upgrade. Keep this
# list in sync with the unifi-update.sh hold/unhold logic.
UBIQUITI_HELD_PACKAGES=(
    unifi-protect
    unifi-access
    unifi-core
    ds
    ulp-go
    uid-agent
    ai-feature-console
    unifi-user-assets
    unifi-face-shared-lib
    uos-discovery-client
    ubnt-archive-keyring
)

# Only hold packages that are actually installed. apt-mark accepts
# non-installed package names but emits warnings; filter them out for
# a cleaner install log.
TO_HOLD=()
for pkg in "${UBIQUITI_HELD_PACKAGES[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        TO_HOLD+=("$pkg")
    fi
done

if [ "${#TO_HOLD[@]}" -gt 0 ]; then
    apt-mark hold "${TO_HOLD[@]}"
    echo "    Held ${#TO_HOLD[@]} Ubiquiti packages."
    echo "    A plain 'apt-get upgrade' will skip these. Use unifi-update.sh"
    echo "    to update them, or 'apt-mark unhold <pkg>' to override."
fi

echo ">>> Phase 12 complete."

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
echo "NEXT STEPS:"
echo ""
echo "1. If you renamed the network interface, update"
echo "   /etc/network/interfaces to use '$PRIMARY_INTERFACE'"
echo ""
echo "2. Reboot: systemctl reboot"
echo ""
echo "3. Navigate to https://<VM-IP> for initial setup"
echo "   Complete setup"
echo ""
echo "4. IMMEDIATELY go to Console Settings and"
echo "   DISABLE auto-update for BOTH UniFi OS and applications"
echo ""
echo "5. Add cameras to Protect"
echo ""
echo "STORAGE:"
echo "  /dev/md3 mounted at /volume1"
echo "  /srv -> /volume1/.srv (symlink)"
echo "  Video recordings: /data/unifi-protect/video/pool/"
echo "  Storage reported via ustorage: $(df -h /srv | awk 'NR==2 {print $2}')"
echo ""
echo "LOGS:"
echo "  journalctl -f"
echo "  /data/unifi-protect/logs/"
echo "  /data/unifi-core/logs/"
echo ""
echo "KNOWN LIMITATIONS:"
echo "  - Storage Manager UI may hang (cosmetic — usd disabled)"
echo "  - Storage disk slots show empty (cosmetic — recording works)"
echo ""

if [ -n "${SMARTCTL_PROXY:-}" ]; then
    echo "SMARTCTL PROXY — HOST SETUP REQUIRED:"
    echo ""
    echo "The smartctl proxy is installed but not yet functional. Finish"
    echo "the setup on the Mac host (see the README 'smartctl proxy'"
    echo "section for the full walkthrough):"
    echo ""
    echo "  1. Edit /etc/default/smartctl-proxy in this VM — set PROXY_HOST"
    echo "     to the Mac's LAN IP and PROXY_USER to your macOS username."
    echo ""
    echo "  2. On the Mac: brew install smartmontools, enable Remote Login,"
    echo "     install smartctl-host-helper.sh, and add a sudoers rule."
    echo ""
    echo "  3. Add this VM's public key to the Mac user's authorized_keys"
    echo "     with a forced command. The public key is:"
    echo ""
    if [ -f /etc/protect-smartctl-proxy/id_ed25519.pub ]; then
        echo "    $(cat /etc/protect-smartctl-proxy/id_ed25519.pub)"
    else
        echo "    (key not found at /etc/protect-smartctl-proxy/id_ed25519.pub)"
    fi
    echo ""
    echo "Until then, smartctl falls back to the local real binary."
    echo ""
fi
