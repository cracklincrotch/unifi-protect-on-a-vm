#!/bin/bash
###############################################################################
# unifi-update.sh
#
# Unified update script for the UniFi Protect VM.
#
# WHAT THIS REPLACES
#
# On a UNVR, updates are handled by the web UI's automatic update mechanism.
# On our VM, that mechanism doesn't always work properly because:
#   - It re-enables services we've masked (usd, usdbd, etc.)
#   - It may try to install kernel packages that break VM boot
#   - It depends on hardware state queries that fail
#
# This script does the same job in a controlled way:
#   - Queries Ubiquiti's firmware API (same endpoint the UNVR uses)
#   - Downloads with SHA256 verification
#   - Excludes packages that don't apply to VMs (linux-image, unvr-initramfs)
#   - Re-masks VM-incompatible services after install in case they got
#     unmasked by package post-install scripts
#   - Shows you what will change before doing anything
#
# WHAT IT CAN UPDATE
#
#   sync-os: Pulls the entire UNVR firmware, extracts and repacks all
#            Ubiquiti packages, installs them. Use this to follow UniFi
#            OS major releases (5.0.13 -> 5.0.16 etc).
#   protect: Just the Protect and AI Feature Console debs.
#   access:  Just the Access deb.
#   all:     Sync OS, then upgrade Protect + Access on top.
#
# Each command has a --check mode (the default) that just shows what
# would change without doing anything.
#
# Usage:
#   ./unifi-update.sh                # Show what would be updated, no changes
#   ./unifi-update.sh --check        # Same as default
#   ./unifi-update.sh --sync-os      # Sync UniFi OS packages to latest firmware
#   ./unifi-update.sh --protect      # Upgrade Protect to latest stable
#   ./unifi-update.sh --protect-edge # Upgrade Protect to latest edge
#   ./unifi-update.sh --access       # Upgrade Access to latest stable
#   ./unifi-update.sh --access-edge  # Upgrade Access to latest edge
#   ./unifi-update.sh --all          # Sync OS + Protect + Access to stable
#   ./unifi-update.sh --all-edge     # Sync OS + Protect + Access to edge
#   ./unifi-update.sh --yes          # Skip confirmation prompts
#
# Environment overrides (rarely needed):
#   FW_URL              - Override UNVR firmware download URL
#   PROTECT_URL         - Override Protect deb download URL
#   AIFC_URL            - Override AI Feature Console deb download URL
#   ACCESS_URL          - Override Access deb download URL
#   PROTECT_CHANNEL     - 'release' (stable) or 'beta' (edge), default 'release'
#   KEEP_WORKDIR        - Set to 1 to keep /opt/unifi-update after running
#                         (default: clean up to save space — /opt lives on
#                         the small root partition, fills quickly)
#
# Run as root.
###############################################################################

# Strict mode: catch errors early.
set -euo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

WORKDIR="/opt/unifi-update"
PLATFORM="UNVR"
DEB_PLATFORM="uos-deb11-arm64"

PROTECT_CHANNEL="${PROTECT_CHANNEL:-release}"

# Ubiquiti firmware API endpoints
FW_API="https://fw-update.ubnt.com/api/firmware-latest"

# Default action
ACTION="check"
ASSUME_YES=0

# Packages held by the install script to prevent uncoordinated apt-get
# upgrades. We unhold these before doing our installs and re-hold them
# afterward. Keep this list in sync with install-protect-baremetal.sh.
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

# Unhold Ubiquiti packages so apt can upgrade them. Only operates on
# packages that are actually installed; skips warnings about missing ones.
unhold_ubiquiti_packages() {
    local to_unhold=()
    for pkg in "${UBIQUITI_HELD_PACKAGES[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            to_unhold+=("$pkg")
        fi
    done
    if [ "${#to_unhold[@]}" -gt 0 ]; then
        apt-mark unhold "${to_unhold[@]}" >/dev/null
    fi
}

# Re-hold Ubiquiti packages after installation. Inverse of unhold_ubiquiti_packages.
hold_ubiquiti_packages() {
    local to_hold=()
    for pkg in "${UBIQUITI_HELD_PACKAGES[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            to_hold+=("$pkg")
        fi
    done
    if [ "${#to_hold[@]}" -gt 0 ]; then
        apt-mark hold "${to_hold[@]}" >/dev/null
    fi
}

###############################################################################
# ARGUMENT PARSING
###############################################################################

while [ $# -gt 0 ]; do
    case "$1" in
        --check)        ACTION="check" ;;
        --sync-os)      ACTION="sync-os" ;;
        --protect)      ACTION="protect"; PROTECT_CHANNEL="release" ;;
        --protect-edge) ACTION="protect"; PROTECT_CHANNEL="beta" ;;
        --access)       ACTION="access"; PROTECT_CHANNEL="release" ;;
        --access-edge)  ACTION="access"; PROTECT_CHANNEL="beta" ;;
        --all)          ACTION="all"; PROTECT_CHANNEL="release" ;;
        --all-edge)     ACTION="all"; PROTECT_CHANNEL="beta" ;;
        --yes|-y)       ASSUME_YES=1 ;;
        --help|-h)
            sed -n '2,32p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
    shift
done

###############################################################################
# VALIDATION
###############################################################################

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

for cmd in wget jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Installing $cmd..."
        apt-get install -y "$cmd"
    fi
done

mkdir -p "$WORKDIR"

###############################################################################
# HELPERS
###############################################################################

confirm() {
    local prompt="$1"
    if [ "$ASSUME_YES" = "1" ]; then
        return 0
    fi
    echo ""
    read -p "$prompt [y/N]: " response
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Strongly recommend taking a host-side snapshot before risky operations.
# Snapshots are instant copy-on-write checkpoints of the VM disks; they're
# the fast rollback path if an upgrade breaks something. The VM itself
# can't take the snapshot (the disk has to be idle for qemu-img to work
# safely), so we just remind the user.
#
# Skipped if --yes was passed (assumes automation/scripted use where the
# operator has already handled rollback strategy).
recommend_snapshot() {
    local description="$1"
    if [ "$ASSUME_YES" = "1" ]; then
        return 0
    fi
    cat <<EOF

==============================================
RECOMMENDED: Take a snapshot before proceeding
==============================================

About to: $description

This operation can fail or leave the system in a broken state. A snapshot
of the VM disks gives you a one-command rollback path. Snapshots are
fast (the VM pauses for a few seconds), take no extra space until data
changes, and can be deleted later.

To take one — no VM shutdown required:
  1. Press Ctrl+C now to abort this script
  2. On the host:  ./snapshot.sh create-auto pre-update
  3. The VM will pause ~2-5 seconds while the snapshot is taken
  4. Re-run this command

If you've already taken a snapshot — or accept the risk of no rollback —
press Enter to continue.

EOF
    read -r -p "Press Enter to continue: "
}

api_get() {
    local url="$1"
    wget -q -O - "$url" 2>/dev/null || curl -sS "$url"
}

# Query the firmware API for latest version info
# Args: product, channel, platform
# Output: JSON object with version, url, sha256, file_size
get_latest_version() {
    local product="$1"
    local channel="$2"
    local platform="$3"

    local url="${FW_API}?filter=eq~~product~~${product}&filter=eq~~channel~~${channel}&filter=eq~~platform~~${platform}"
    local response

    response=$(api_get "$url")
    if [ -z "$response" ]; then
        echo "ERROR: Failed to query API for $product/$channel/$platform" >&2
        return 1
    fi

    echo "$response" | jq -r '._embedded.firmware[0] | {
        version: .version,
        url: ._links.data.href,
        sha256: .sha256_checksum,
        size: .file_size
    }'
}

# Print a version comparison line
print_version() {
    local label="$1"
    local current="$2"
    local latest="$3"
    if [ "$current" = "$latest" ]; then
        printf "    %-30s %s (up to date)\n" "$label" "$current"
    else
        printf "    %-30s %s -> %s\n" "$label" "$current" "$latest"
    fi
}

# Download a file with checksum verification
# Args: url, output_path, expected_sha256
download_verified() {
    local url="$1"
    local output="$2"
    local expected_sha="$3"

    if [ -f "$output" ]; then
        local actual_sha
        actual_sha=$(sha256sum "$output" | awk '{print $1}')
        if [ "$actual_sha" = "$expected_sha" ]; then
            echo "    Already downloaded and verified: $(basename "$output")"
            return 0
        fi
        echo "    Existing file failed checksum, redownloading..."
        rm -f "$output"
    fi

    echo "    Downloading: $url"
    wget --no-verbose --show-progress --progress=dot:giga -O "$output" "$url"

    local actual_sha
    actual_sha=$(sha256sum "$output" | awk '{print $1}')
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "ERROR: Checksum mismatch for $output"
        echo "  Expected: $expected_sha"
        echo "  Got:      $actual_sha"
        return 1
    fi
    echo "    Verified: $(basename "$output")"
}

###############################################################################
# QUERY LATEST VERSIONS
###############################################################################

echo "=============================================="
echo "UniFi Update — Querying latest versions..."
echo "=============================================="
echo ""

echo ">>> Fetching firmware metadata from Ubiquiti..."

FW_INFO=$(get_latest_version "unifi-nvr" "release" "$PLATFORM")
PROTECT_INFO=$(get_latest_version "unifi-protect" "$PROTECT_CHANNEL" "$DEB_PLATFORM")
AIFC_INFO=$(get_latest_version "ai-feature-console" "$PROTECT_CHANNEL" "$DEB_PLATFORM")
ACCESS_INFO=$(get_latest_version "unifi-access" "$PROTECT_CHANNEL" "$DEB_PLATFORM")

FW_VERSION=$(echo "$FW_INFO" | jq -r '.version')
FW_DOWNLOAD_URL=$(echo "$FW_INFO" | jq -r '.url')
FW_SHA=$(echo "$FW_INFO" | jq -r '.sha256')

PROTECT_VERSION=$(echo "$PROTECT_INFO" | jq -r '.version')
PROTECT_DOWNLOAD_URL=$(echo "$PROTECT_INFO" | jq -r '.url')
PROTECT_SHA=$(echo "$PROTECT_INFO" | jq -r '.sha256')

AIFC_VERSION=$(echo "$AIFC_INFO" | jq -r '.version')
AIFC_DOWNLOAD_URL=$(echo "$AIFC_INFO" | jq -r '.url')
AIFC_SHA=$(echo "$AIFC_INFO" | jq -r '.sha256')

ACCESS_VERSION=$(echo "$ACCESS_INFO" | jq -r '.version')
ACCESS_DOWNLOAD_URL=$(echo "$ACCESS_INFO" | jq -r '.url')
ACCESS_SHA=$(echo "$ACCESS_INFO" | jq -r '.sha256')

# Allow URL overrides
FW_DOWNLOAD_URL="${FW_URL:-$FW_DOWNLOAD_URL}"
PROTECT_DOWNLOAD_URL="${PROTECT_URL:-$PROTECT_DOWNLOAD_URL}"
AIFC_DOWNLOAD_URL="${AIFC_URL:-$AIFC_DOWNLOAD_URL}"
ACCESS_DOWNLOAD_URL="${ACCESS_URL:-$ACCESS_DOWNLOAD_URL}"

###############################################################################
# CURRENT VERSIONS
###############################################################################

CURRENT_OS_VERSION=$(cat /usr/lib/version 2>/dev/null | tr -d '\n' || echo "unknown")
CURRENT_PROTECT=$(dpkg-query -W -f='${Version}' unifi-protect 2>/dev/null || echo "not installed")
CURRENT_AIFC=$(dpkg-query -W -f='${Version}' ai-feature-console 2>/dev/null || echo "not installed")
CURRENT_ACCESS=$(dpkg-query -W -f='${Version}' unifi-access 2>/dev/null || echo "not installed")
CURRENT_DS=$(dpkg-query -W -f='${Version}' ds 2>/dev/null || echo "not installed")
CURRENT_CORE=$(dpkg-query -W -f='${Version}' unifi-core 2>/dev/null || echo "not installed")

echo ""
echo "Current versions:"
print_version "UniFi OS"          "$CURRENT_OS_VERSION" "$FW_VERSION"
print_version "unifi-protect"     "$CURRENT_PROTECT"    "$PROTECT_VERSION"
print_version "ai-feature-console" "$CURRENT_AIFC"      "$AIFC_VERSION"
print_version "unifi-access"      "$CURRENT_ACCESS"     "$ACCESS_VERSION"
echo "    (Other packages compared during sync)"
echo ""
echo "Channel: $PROTECT_CHANNEL"
echo ""

if [ "$ACTION" = "check" ]; then
    echo "Run with --sync-os, --protect, --protect-edge, --all, or --all-edge to apply updates."
    exit 0
fi

###############################################################################
# SYNC UNIFI OS PACKAGES
###############################################################################

sync_os_packages() {
    echo ""
    echo "=============================================="
    echo "Syncing UniFi OS packages to $FW_VERSION"
    echo "=============================================="

    # Ensure extraction tools
    for cmd in binwalk unsquashfs dpkg-repack; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo ">>> Installing $cmd..."
            case "$cmd" in
                binwalk)       pip3 install binwalk --break-system-packages 2>/dev/null || pip3 install binwalk ;;
                unsquashfs)    apt-get install -y squashfs-tools ;;
                dpkg-repack)   apt-get install -y dpkg-repack ;;
            esac
        fi
    done

    echo ""
    echo ">>> Downloading firmware..."
    download_verified "$FW_DOWNLOAD_URL" "$WORKDIR/fwupdate.bin" "$FW_SHA"

    echo ""
    echo ">>> Extracting firmware..."
    cd "$WORKDIR"
    rm -rf _fwupdate.bin*extracted
    binwalk -e fwupdate.bin >/dev/null 2>&1 || true

    local sqfs_root
    sqfs_root=$(find "$WORKDIR" -name "squashfs-root" -type d | head -1)
    if [ -z "$sqfs_root" ]; then
        echo "ERROR: Could not find squashfs-root"
        exit 1
    fi
    echo "    Squashfs root: $sqfs_root"

    echo ""
    echo ">>> Identifying Ubiquiti packages..."
    mkdir -p "$WORKDIR/debs"
    rm -f "$WORKDIR/debs/"*.deb 2>/dev/null || true

    dpkg-query --admindir="$sqfs_root/var/lib/dpkg/" -W -f='${package} | ${Maintainer}\n' | \
        grep -E '@ubnt.com|@ui.com' | cut -d '|' -f 1 > "$WORKDIR/packages.txt"

    echo ""
    echo "    Version diff (current -> firmware):"
    local has_changes=0
    while read -r pkg; do
        # Skip packages we won't install on VMs
        case "$pkg" in
            linux-image-*|unvr-initramfs)
                continue
                ;;
        esac
        local current latest
        current=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "not installed")
        latest=$(dpkg-query --admindir="$sqfs_root/var/lib/dpkg/" -W -f='${Version}' "$pkg" 2>/dev/null || echo "N/A")
        if [ "$current" != "$latest" ]; then
            printf "    %-40s %s -> %s\n" "$pkg" "$current" "$latest"
            has_changes=1
        fi
    done < "$WORKDIR/packages.txt"

    if [ "$has_changes" = "0" ]; then
        echo "    No package changes detected. OS is already in sync."
        return 0
    fi

    if ! confirm "Apply these package changes?"; then
        echo "Aborted by user."
        return 1
    fi

    echo ""
    echo ">>> Repacking packages..."
    cd "$WORKDIR/debs"
    while read -r pkg; do
        echo "      Repacking: $pkg"
        dpkg-repack --root="$sqfs_root" --arch=arm64 "$pkg" >/dev/null 2>&1 || \
            echo "      WARNING: Failed to repack $pkg"
    done < "$WORKDIR/packages.txt"

    # Don't install UNVR kernel — VM uses its own
    rm -f "$WORKDIR/debs/linux-image-"*.deb

    # Don't install unvr-initramfs — adds boot scripts that wait for UNVR hardware
    # (MTD flash, eMMC) and break boot on VMs
    rm -f "$WORKDIR/debs/unvr-initramfs"*.deb

    echo ""
    echo ">>> Stopping services..."
    systemctl stop unifi-protect ai-feature-console ds unifi-core ulp-go uid-agent 2>/dev/null || true

    echo ""
    echo ">>> Installing packages..."
    # Unhold so apt can replace Ubiquiti packages. Re-hold at end.
    unhold_ubiquiti_packages
    apt-get install -y --allow-downgrades --no-install-recommends \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        "$WORKDIR/debs/"*.deb || \
            echo "    NOTE: Some installs failed. The initramfs mtd-utils hook error is harmless."
    hold_ubiquiti_packages

    echo ""
    echo ">>> Updating /usr/lib/version..."
    cp "$sqfs_root/usr/lib/version" /usr/lib/version
    echo "    System version is now: $(cat /usr/lib/version)"

    echo ""
    echo ">>> Masking VM-incompatible services..."
    # These services expect real UNVR hardware and fail on VMs.
    # Mask (not just disable) because they're triggered as dependencies
    # of other services like ustated, regardless of whether they're enabled.
    for svc in usd usdbd rpsd uhwd sfp sfpd; do
        systemctl stop "${svc}.service" 2>/dev/null || true
        systemctl mask "${svc}.service" 2>/dev/null || true
    done

    echo ""
    echo ">>> Restarting services..."
    systemctl daemon-reload
    systemctl start uid-agent ulp-go unifi-core ds ai-feature-console unifi-protect 2>/dev/null || true
}

###############################################################################
# UPGRADE PROTECT
###############################################################################

upgrade_protect() {
    echo ""
    echo "=============================================="
    echo "Upgrading Protect to $PROTECT_VERSION ($PROTECT_CHANNEL)"
    echo "AI Feature Console to $AIFC_VERSION"
    echo "=============================================="

    if [ "$CURRENT_PROTECT" = "$PROTECT_VERSION" ] && [ "$CURRENT_AIFC" = "$AIFC_VERSION" ]; then
        echo "    Already at latest versions. Nothing to do."
        return 0
    fi

    if ! confirm "Proceed with Protect upgrade?"; then
        echo "Aborted by user."
        return 1
    fi

    echo ""
    echo ">>> Downloading Protect..."
    download_verified "$PROTECT_DOWNLOAD_URL" "$WORKDIR/unifi-protect.deb" "$PROTECT_SHA"

    echo ""
    echo ">>> Downloading AI Feature Console..."
    download_verified "$AIFC_DOWNLOAD_URL" "$WORKDIR/ai-feature-console.deb" "$AIFC_SHA"

    echo ""
    echo ">>> Stopping services..."
    systemctl stop unifi-protect ai-feature-console 2>/dev/null || true

    echo ""
    echo ">>> Installing..."
    unhold_ubiquiti_packages
    apt-get install -y --allow-downgrades --no-install-recommends \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        "$WORKDIR/unifi-protect.deb" "$WORKDIR/ai-feature-console.deb"
    hold_ubiquiti_packages

    echo ""
    echo ">>> Restarting services..."
    systemctl daemon-reload
    systemctl start ai-feature-console unifi-protect 2>/dev/null || true
}

###############################################################################
# UPGRADE ACCESS
###############################################################################

upgrade_access() {
    echo ""
    echo "=============================================="
    echo "Upgrading Access to $ACCESS_VERSION ($PROTECT_CHANNEL)"
    echo "=============================================="

    if [ "$CURRENT_ACCESS" = "$ACCESS_VERSION" ]; then
        echo "    Already at latest version. Nothing to do."
        return 0
    fi

    if ! confirm "Proceed with Access ${CURRENT_ACCESS:-install}?"; then
        echo "Aborted by user."
        return 1
    fi

    echo ""
    echo ">>> Downloading Access..."
    download_verified "$ACCESS_DOWNLOAD_URL" "$WORKDIR/unifi-access.deb" "$ACCESS_SHA"

    echo ""
    echo ">>> Stopping Access service..."
    systemctl stop unifi-access 2>/dev/null || true

    echo ""
    echo ">>> Installing..."
    # Preseed coturn so it doesn't prompt on first install
    echo "coturn coturn/install-as-service boolean false" | debconf-set-selections

    unhold_ubiquiti_packages
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades --no-install-recommends \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        "$WORKDIR/unifi-access.deb"
    hold_ubiquiti_packages

    echo ""
    echo ">>> Restarting Access..."
    systemctl daemon-reload
    systemctl start unifi-access 2>/dev/null || true
}

###############################################################################
# EXECUTE ACTION
###############################################################################

case "$ACTION" in
    sync-os)
        recommend_snapshot "sync UniFi OS packages to $FW_VERSION"
        sync_os_packages
        ;;
    protect)
        recommend_snapshot "upgrade Protect to $PROTECT_VERSION + AI FC to $AIFC_VERSION"
        upgrade_protect
        ;;
    access)
        recommend_snapshot "upgrade Access to $ACCESS_VERSION"
        upgrade_access
        ;;
    all)
        recommend_snapshot "sync UniFi OS + upgrade Protect + upgrade Access"
        sync_os_packages
        upgrade_protect
        upgrade_access
        ;;
esac

###############################################################################
# REPORT
###############################################################################

echo ""
echo "=============================================="
echo "Update complete!"
echo "=============================================="
echo ""

NEW_OS=$(cat /usr/lib/version 2>/dev/null | tr -d '\n' || echo "unknown")
NEW_PROTECT=$(dpkg-query -W -f='${Version}' unifi-protect 2>/dev/null || echo "not installed")
NEW_AIFC=$(dpkg-query -W -f='${Version}' ai-feature-console 2>/dev/null || echo "not installed")
NEW_ACCESS=$(dpkg-query -W -f='${Version}' unifi-access 2>/dev/null || echo "not installed")

echo "Installed versions:"
echo "    UniFi OS:           $NEW_OS"
echo "    unifi-protect:      $NEW_PROTECT"
echo "    ai-feature-console: $NEW_AIFC"
echo "    unifi-access:       $NEW_ACCESS"
echo ""
echo "Service status:"
for svc in unifi-core unifi-protect ds ai-feature-console ulp-go uid-agent unifi-access; do
    if systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
        local_status=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
        printf "    %-25s %s\n" "$svc" "$local_status"
    fi
done

if [ "${KEEP_WORKDIR:-0}" != "1" ]; then
    echo ""
    echo "Cleaning up $WORKDIR (set KEEP_WORKDIR=1 to retain)..."
    # Remove everything by default since /opt may live on the small root partition.
    # The firmware download was 700MB, the extraction adds another 2GB, plus debs.
    # Keep nothing unless explicitly asked.
    rm -rf "$WORKDIR/_fwupdate.bin"*extracted \
           "$WORKDIR/debs" \
           "$WORKDIR/fwupdate.bin" \
           "$WORKDIR/unifi-protect.deb" \
           "$WORKDIR/ai-feature-console.deb" \
           "$WORKDIR/unifi-access.deb" \
           "$WORKDIR/packages.txt"
fi

echo ""
