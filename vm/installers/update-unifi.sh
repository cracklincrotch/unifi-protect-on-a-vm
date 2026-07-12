#!/bin/bash
###############################################################################
# update-unifi.sh
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
#   protect: Just the Protect and AI Feature Controller debs.
#   access:  Just the Access deb.
#   all:     Sync OS, then upgrade Protect + Access on top.
#
# Each command has a --check mode (the default) that just shows what
# would change without doing anything.
#
# Usage:
#   ./update-unifi.sh                # Show what would be updated, no changes
#   ./update-unifi.sh --check        # Same as default
#   ./update-unifi.sh --sync-os      # Sync UniFi OS packages to latest firmware
#   ./update-unifi.sh --protect      # Upgrade Protect to latest stable
#   ./update-unifi.sh --protect-edge # Upgrade Protect to latest edge
#   ./update-unifi.sh --access       # Upgrade Access to latest stable
#   ./update-unifi.sh --access-edge  # Upgrade Access to latest edge
#   ./update-unifi.sh --all          # Sync OS + Protect + Access to stable
#   ./update-unifi.sh --all-edge     # Sync OS + Protect + Access to edge
#   ./update-unifi.sh --yes          # Skip confirmation prompts
#   ./update-unifi.sh --verify       # Check the storage/shim invariants (read-only)
#
# Environment overrides (rarely needed):
#   FW_URL              - Override UNVR firmware download URL
#   PROTECT_URL         - Override Protect deb download URL
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

# Directory this script lives in — used to locate sibling installers
# (install-shims.sh, install-storage.sh) for post-sync-os shim reconciliation.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROTECT_CHANNEL="${PROTECT_CHANNEL:-release}"

# Ubiquiti firmware API endpoints
FW_API="https://fw-update.ubnt.com/api/firmware-latest"

# Default action
ACTION="check"
ASSUME_YES=0

# Ubiquiti packages are version-PINNED (APT preferences, not dpkg-hold) to stop
# uncoordinated `apt-get upgrade` runs from upgrading them outside this script.
# dpkg-hold is avoided because `uos runnable current-version` reports a HELD
# package as "not installed", which makes Protect's whole-system backup abort
# ("Invalid version"); a pin keeps the dpkg status "install ok installed". We
# drop the pin before our installs and rewrite it afterward. The set is derived
# at run time by ubiquiti_packages() (see HELPERS) — no static list to sync.
UBNT_PIN_FILE=/etc/apt/preferences.d/50-ubiquiti-pin

# Write the APT pin for the current Ubiquiti package set.
write_ubiquiti_pin() {
    local pkgs
    pkgs="$(ubiquiti_packages | tr '\n' ' ')"
    [ -n "$pkgs" ] || return 0
    {
        echo "# Ubiquiti packages pinned so 'apt-get upgrade' won't bump them,"
        echo "# while dpkg status stays 'install ok installed'. dpkg-hold would"
        echo "# break 'uos runnable current-version' => Protect backup fails."
        echo "# Managed by update-unifi.sh; regenerated on each run."
        echo "Package: $pkgs"
        echo "Pin: version *"
        echo "Pin-Priority: -1"
    } > "$UBNT_PIN_FILE"
}

# Unlock Ubiquiti packages so apt can (re)install them: drop the pin, and clear
# any legacy dpkg-holds left by older installs. (Name kept for call sites.)
unhold_ubiquiti_packages() {
    local pkgs
    pkgs="$(ubiquiti_packages)"
    rm -f "$UBNT_PIN_FILE"
    [ -n "$pkgs" ] && apt-mark unhold $pkgs >/dev/null 2>&1 || true
}

# Re-lock Ubiquiti packages after installation: rewrite the pin for the current
# set. Does NOT dpkg-hold (that breaks the Protect backup via uos).
hold_ubiquiti_packages() {
    write_ubiquiti_pin
}

# Post-update storage/shim health check. Read-only; prints per-check OK/FAIL and
# returns non-zero if anything failed. Run automatically at the end of a sync-os
# and on demand via --verify. Defined here (before arg parsing) so both the
# --verify early-exit and sync_os_packages can call it.
verify_shims() {
    local fail=0 sj=/usr/share/unifi-core/app/service.js
    _ck() { if [ "$1" -eq 0 ]; then printf "    [ OK ] %s\n" "$2"; else printf "    [FAIL] %s\n" "$2"; fail=1; fi; }
    set +e
    [ "$(grep -cF '["disk","inspect"]' "$sj" 2>/dev/null)" = 1 ]; _ck $? "service.js Patch A (disk list)"
    [ "$(grep -cF ',!0?s.push' "$sj" 2>/dev/null)" = 1 ];        _ck $? "service.js Patch B (drive detect)"
    head -3 /usr/bin/ustorage 2>/dev/null | grep -q 'ustorage-vm'; _ck $? "/usr/bin/ustorage is the VM shim"
    systemctl is-active --quiet ustated-shim.service;             _ck $? "ustated-shim.service active"
    ss -ltn 2>/dev/null | grep -q '127\.0\.0\.1:11052';           _ck $? "ustated-shim listening on :11052"
    { [ "$(systemctl is-enabled usd.service 2>/dev/null)" = masked ] &&
      [ "$(systemctl is-enabled ustated.service 2>/dev/null)" = masked ]; }; _ck $? "usd + ustated masked"
    grep -q 'UUUU' /proc/mdstat 2>/dev/null;                      _ck $? "md array [UUUU]"
    [ -s /var/run/anonymous_device_id ];                          _ck $? "anonymous_device_id present"
    printf "    versions: unifi-core=%s unifi-protect=%s node=%s\n" \
        "$(dpkg-query -W -f='${Version}' unifi-core 2>/dev/null || echo '?')" \
        "$(dpkg-query -W -f='${Version}' unifi-protect 2>/dev/null || echo '?')" \
        "$(node --version 2>/dev/null || echo '?')"
    set -e
    return $fail
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
        --verify)       ACTION="verify" ;;
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

# --verify is a local, read-only health check — no firmware/version query needed.
if [ "$ACTION" = "verify" ]; then
    echo "=== storage / shim verification ==="
    verify_shims && { echo "All checks passed."; exit 0; } \
                 || { echo "One or more checks FAILED — review above."; exit 1; }
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

# Take a host-side snapshot before risky operations. Snapshots are
# instant copy-on-write checkpoints of the VM disks — the fast rollback
# path if an upgrade breaks something.
#
# The VM can't snapshot its own disks directly, but it CAN ask the host
# to over the control channel: protect-on-mac-ctl sends a `snapshot`
# request, the host pauses the VM briefly, runs qemu-img, and resumes.
# If the channel isn't available we fall back to advising a manual one.
recommend_snapshot() {
    local description="$1"
    local ctl=/usr/local/bin/protect-on-mac-ctl
    local label="pre-update-$(date +%Y%m%d-%H%M%S)"

    if [ -x "$ctl" ]; then
        echo ">>> Taking a pre-update snapshot via the control channel:"
        echo "    $label"
        if "$ctl" snapshot "$label"; then
            echo ">>> Snapshot created. Roll back later with:"
            echo "    snapshot.sh restore $label"
            return 0
        fi
        echo "WARNING: automatic snapshot failed (control channel down or" >&2
        echo "         snapshot error) — see the message above." >&2
    fi

    # No control channel, or the snapshot attempt failed.
    if [ "$ASSUME_YES" = "1" ]; then
        echo "WARNING: proceeding WITHOUT a pre-update snapshot (--yes set)." >&2
        return 0
    fi
    cat <<EOF

==============================================
RECOMMENDED: Take a snapshot before proceeding
==============================================

About to: $description

No automatic snapshot was taken. This operation can fail or leave the
system in a broken state — a snapshot gives you a one-command rollback.

To take one manually — no VM shutdown required:
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

    echo "    Downloading:"
    echo "      $url"
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

# Install binwalk 2.x from the v2.3.4 GitHub tag. Do NOT `pip3 install
# binwalk` from PyPI: that resolves to binwalk 2.4.x, whose sdist is
# broken — it omits every submodule, so `binwalk -e` later dies with
# "ModuleNotFoundError: No module named 'binwalk.core'". The v2.3.4 tag
# is the last good Python release (the repo default branch is now the
# unrelated Rust rewrite, binwalk 3).
install_binwalk() {
    local tag=v2.3.4 tmp src
    tmp=$(mktemp -d)
    wget --no-verbose -O "$tmp/binwalk.tar.gz" \
        "https://github.com/ReFirmLabs/binwalk/archive/refs/tags/${tag}.tar.gz"
    tar -xzf "$tmp/binwalk.tar.gz" -C "$tmp"
    src=$(find "$tmp" -maxdepth 1 -type d -name 'binwalk-*' | head -1)
    pip3 install "$src" --break-system-packages 2>/dev/null \
        || pip3 install "$src"
    rm -rf "$tmp"
    binwalk --help >/dev/null 2>&1 \
        || { echo "ERROR: binwalk install failed" >&2; exit 1; }
}

# Parse EVERY ai-feature-* dependency out of a .deb's Depends field.
# Args:   path to a .deb (the Protect deb)
# Output: one "<package> <version>" line per ai-feature-* dependency;
#         version is the constraint version, or absent if unversioned.
#
# Protect declares its AI packages by name in Depends, and the set has
# changed over versions — Protect 7.x depends on BOTH ai-feature-console
# AND ai-feature-controller, each pinned to an exact version. Reading
# them all from the deb (rather than hardcoding names) means an added,
# removed or renamed AI package is picked up with no code change.
ai_deps_of_deb() {
    local deb="$1" depends entry name ver
    depends="$(dpkg-deb -f "$deb" Depends 2>/dev/null)" || return 0
    local IFS=','
    for entry in $depends; do
        case "$entry" in
            *ai-feature-*)
                name="$(echo "$entry" | grep -oE 'ai-feature-[a-z0-9-]+' \
                    | head -1)"
                ver="$(echo "$entry" | grep -oE '[0-9][0-9a-zA-Z.+~:-]*' \
                    | head -1)"
                [ -n "$name" ] && echo "$name $ver"
                ;;
        esac
    done
}

# Best-effort pre-flight: warn about any non-ai Protect dependency the
# running system does not have installed. Pure warning — apt still
# decides. Catches the common "ran --protect without --sync-os first"
# case and turns a cryptic apt dependency dump into a plain heads-up.
preflight_protect_deps() {
    local deb="$1" depends entry name missing=0
    depends="$(dpkg-deb -f "$deb" Depends 2>/dev/null)" || return 0
    local IFS=','
    for entry in $depends; do
        name="$(echo "$entry" \
            | sed -E 's/^[[:space:]]*([a-z0-9][a-z0-9.+-]*).*/\1/')"
        [ -n "$name" ] || continue
        case "$name" in ai-feature-*) continue ;; esac
        if ! dpkg-query -W -f='${Status}' "$name" 2>/dev/null \
             | grep -q "install ok installed"; then
            echo "    NOTE: Protect needs '$name' — not installed." >&2
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        echo "    Run 'update-unifi.sh --sync-os' first (or --all) to" >&2
        echo "    install the OS packages Protect depends on." >&2
    fi
    return 0
}

# The installed Ubiquiti packages to pin/unpin around our installs.
# Derived at run time: every installed package whose Maintainer is a
# Ubiquiti address. Deriving it (rather than hardcoding a list) means a
# newly introduced Ubiquiti package is pinned automatically and can't be
# silently upgraded by a routine `apt-get upgrade`.
ubiquiti_packages() {
    dpkg-query -W -f='${Package} ${Maintainer}\n' 2>/dev/null \
        | grep -E '@ubnt\.com|@ui\.com' \
        | awk '{print $1}'
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
ACCESS_INFO=$(get_latest_version "unifi-access" "$PROTECT_CHANNEL" "$DEB_PLATFORM")

FW_VERSION=$(echo "$FW_INFO" | jq -r '.version')
FW_DOWNLOAD_URL=$(echo "$FW_INFO" | jq -r '.url')
FW_SHA=$(echo "$FW_INFO" | jq -r '.sha256')

PROTECT_VERSION=$(echo "$PROTECT_INFO" | jq -r '.version')
PROTECT_DOWNLOAD_URL=$(echo "$PROTECT_INFO" | jq -r '.url')
PROTECT_SHA=$(echo "$PROTECT_INFO" | jq -r '.sha256')

ACCESS_VERSION=$(echo "$ACCESS_INFO" | jq -r '.version')
ACCESS_DOWNLOAD_URL=$(echo "$ACCESS_INFO" | jq -r '.url')
ACCESS_SHA=$(echo "$ACCESS_INFO" | jq -r '.sha256')

# Allow URL overrides
FW_DOWNLOAD_URL="${FW_URL:-$FW_DOWNLOAD_URL}"
PROTECT_DOWNLOAD_URL="${PROTECT_URL:-$PROTECT_DOWNLOAD_URL}"
ACCESS_DOWNLOAD_URL="${ACCESS_URL:-$ACCESS_DOWNLOAD_URL}"

# The AI feature packages (ai-feature-console, ai-feature-controller, and
# whatever the set becomes) are NOT queried here: their names are
# whatever the chosen Protect deb declares as dependencies, and
# upgrade_protect resolves the full set from that deb at install time.

###############################################################################
# CURRENT VERSIONS
###############################################################################

CURRENT_OS_VERSION=$(cat /usr/lib/version 2>/dev/null | tr -d '\n' || echo "unknown")
CURRENT_PROTECT=$(dpkg-query -W -f='${Version}' unifi-protect 2>/dev/null || echo "not installed")
CURRENT_ACCESS=$(dpkg-query -W -f='${Version}' unifi-access 2>/dev/null || echo "not installed")
CURRENT_DS=$(dpkg-query -W -f='${Version}' ds 2>/dev/null || echo "not installed")
CURRENT_CORE=$(dpkg-query -W -f='${Version}' unifi-core 2>/dev/null || echo "not installed")

echo ""
echo "Current versions:"
print_version "UniFi OS"          "$CURRENT_OS_VERSION" "$FW_VERSION"
print_version "unifi-protect"     "$CURRENT_PROTECT"    "$PROTECT_VERSION"
print_version "unifi-access"      "$CURRENT_ACCESS"     "$ACCESS_VERSION"
echo "    ai-feature package         resolved from Protect at install"
echo "    (Other packages compared during sync)"
echo ""
echo "Channel: $PROTECT_CHANNEL"
echo ""

if [ "$ACTION" = "check" ]; then
    echo "Run with --sync-os, --protect, --protect-edge, --all, or"
    echo "--all-edge to apply updates, or --verify to check storage health."
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
                binwalk)       install_binwalk ;;
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
    # --run-as=root: binwalk 2.3.x refuses to run its extraction utilities
    # as root unless told to. The VM runs as root, so the flag is required.
    binwalk --run-as=root -e fwupdate.bin >/dev/null 2>&1 || true

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

    # Don't install the application packages bundled in the firmware. The
    # firmware carries an OLD Protect (e.g. 6.2.88) whose dependency on a
    # matching ai-feature-* package can't be satisfied — and apt installs
    # all-or-nothing, so one broken app package aborts the WHOLE OS sync
    # (node24, unifi-core, ustd ... all silently skipped). Protect, Access
    # and the AI feature package are upgraded separately by upgrade_protect
    # / upgrade_access, always to the latest release.
    rm -f "$WORKDIR/debs/unifi-protect_"*.deb \
          "$WORKDIR/debs/ai-feature-console_"*.deb \
          "$WORKDIR/debs/ai-feature-controller_"*.deb \
          "$WORKDIR/debs/unifi-access_"*.deb

    echo ""
    echo ">>> Stopping services..."
    systemctl stop unifi-protect ai-feature-controller ds unifi-core ulp-go uid-agent 2>/dev/null || true

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
    # of other services regardless of whether they're enabled. ustated is
    # masked too — the ustated-shim replaces it.
    for svc in usd usdbd rpsd uhwd sfp sfpd ustated; do
        systemctl stop "${svc}.service" 2>/dev/null || true
        systemctl mask "${svc}.service" 2>/dev/null || true
    done

    # --sync-os reinstalled the whole @ubnt set, which clobbers the VM shims
    # (ubnt-tools/uled-ctrl/smartctl and the ustd-owned /usr/bin/ustorage) and
    # reverts the service.js patches. Re-lay them from the sibling installers so
    # the storage subsystem comes back correct on the same run — without this,
    # the first post-sync boot serves an unpatched service.js + stock ustorage.
    echo ""
    echo ">>> Reconciling VM shims after the OS sync..."
    if [ -f "$SCRIPT_DIR/install-shims.sh" ]; then
        bash "$SCRIPT_DIR/install-shims.sh" || echo "    WARNING: install-shims.sh returned non-zero — check it"
    else
        echo "    WARNING: $SCRIPT_DIR/install-shims.sh not found — shims NOT reapplied"
    fi
    if [ -f "$SCRIPT_DIR/install-storage.sh" ]; then
        # re-lays /usr/bin/ustorage, re-masks usd+ustated, re-enables the storage
        # units, and re-applies service.js Patch A + Patch B via the boot healer.
        bash "$SCRIPT_DIR/install-storage.sh" || echo "    WARNING: install-storage.sh returned non-zero — check it"
    else
        echo "    WARNING: $SCRIPT_DIR/install-storage.sh not found — ustorage/patches NOT reapplied"
    fi

    echo ""
    echo ">>> Restarting services..."
    systemctl daemon-reload
    # unifi-core must restart so the freshly re-applied service.js patches load.
    systemctl restart unifi-core 2>/dev/null || true
    systemctl start uid-agent ulp-go ds ai-feature-controller unifi-protect 2>/dev/null || true

    echo ""
    echo ">>> Verifying the storage shims survived the OS sync..."
    verify_shims || echo "    WARNING: verification reported issues — review before trusting storage."
}

###############################################################################
# UPGRADE PROTECT
###############################################################################

upgrade_protect() {
    echo ""
    echo "=============================================="
    echo "Upgrading Protect to $PROTECT_VERSION ($PROTECT_CHANNEL)"
    echo "=============================================="

    # dpkg reports "7.1.60"; the API reports "v7.1.60" — strip the v.
    if [ "$CURRENT_PROTECT" = "${PROTECT_VERSION#v}" ]; then
        echo "    Already at $PROTECT_VERSION. Nothing to do."
        return 0
    fi

    if ! confirm "Proceed with Protect upgrade?"; then
        echo "Aborted by user."
        return 1
    fi

    echo ""
    echo ">>> Downloading Protect..."
    download_verified "$PROTECT_DOWNLOAD_URL" "$WORKDIR/unifi-protect.deb" \
        "$PROTECT_SHA"

    # Resolve EVERY ai-feature-* package from Protect's own metadata
    # rather than hardcoded product names. Protect 7.x depends on both
    # ai-feature-console and ai-feature-controller, each pinned exactly;
    # reading the full set from the deb handles additions/removals/renames
    # with no code change.
    echo ""
    echo ">>> Resolving Protect's AI feature dependencies..."
    local ai_pkgs=() ai_debs=() ai_pkg ai_pin
    while read -r ai_pkg ai_pin; do
        [ -n "$ai_pkg" ] || continue
        echo "    Protect $PROTECT_VERSION needs:" \
             "$ai_pkg${ai_pin:+ = $ai_pin}"

        local ai_info ai_url ai_ver ai_sha
        if ! ai_info="$(get_latest_version "$ai_pkg" "$PROTECT_CHANNEL" \
                        "$DEB_PLATFORM")"; then
            echo "ERROR: the firmware API has no product '$ai_pkg'." >&2
            echo "       Protect $PROTECT_VERSION requires it." >&2
            return 1
        fi
        ai_ver="$(echo "$ai_info" | jq -r '.version')"
        ai_sha="$(echo "$ai_info" | jq -r '.sha256')"
        ai_url="$(echo "$ai_info" | jq -r '.url')"

        if [ -n "$ai_pin" ] && [ "${ai_ver#v}" != "$ai_pin" ]; then
            echo "WARNING: Protect pins $ai_pkg = $ai_pin, but the" >&2
            echo "         $PROTECT_CHANNEL channel offers ${ai_ver#v}" >&2
            echo "         — the install may fail on the mismatch." >&2
        fi

        echo ">>> Downloading $ai_pkg ($ai_ver)..."
        download_verified "$ai_url" "$WORKDIR/${ai_pkg}.deb" "$ai_sha"
        ai_pkgs+=("$ai_pkg")
        ai_debs+=("$WORKDIR/${ai_pkg}.deb")
    done < <(ai_deps_of_deb "$WORKDIR/unifi-protect.deb")
    [ "${#ai_pkgs[@]}" -gt 0 ] \
        || echo "    Protect declares no ai-feature-* dependency."

    # Best-effort heads-up about non-ai deps the system lacks (node24,
    # unifi-core ...). Those are installed by --sync-os from the firmware.
    preflight_protect_deps "$WORKDIR/unifi-protect.deb"

    echo ""
    echo ">>> Stopping services..."
    systemctl stop unifi-protect "${ai_pkgs[@]}" 2>/dev/null || true

    echo ""
    echo ">>> Installing..."
    unhold_ubiquiti_packages
    apt-get install -y --allow-downgrades --no-install-recommends \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        "$WORKDIR/unifi-protect.deb" "${ai_debs[@]}"
    hold_ubiquiti_packages

    echo ""
    echo ">>> Restarting services..."
    systemctl daemon-reload
    systemctl start "${ai_pkgs[@]}" unifi-protect 2>/dev/null || true
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
        recommend_snapshot "upgrade Protect to $PROTECT_VERSION"
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
NEW_ACCESS=$(dpkg-query -W -f='${Version}' unifi-access 2>/dev/null || echo "not installed")
# Every installed ai-feature-* package (Protect 7.x has two; names not
# assumed).
NEW_AI_PKGS=()
while read -r p; do
    [ -n "$p" ] && NEW_AI_PKGS+=("$p")
done < <(dpkg-query -W -f='${Package}\n' 'ai-feature-*' 2>/dev/null)

echo "Installed versions:"
echo "    UniFi OS:           $NEW_OS"
echo "    unifi-protect:      $NEW_PROTECT"
for p in "${NEW_AI_PKGS[@]}"; do
    printf "    %-19s %s\n" "$p:" \
        "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo '?')"
done
echo "    unifi-access:       $NEW_ACCESS"
echo ""
echo "Service status:"
for svc in unifi-core unifi-protect ds "${NEW_AI_PKGS[@]}" ulp-go uid-agent unifi-access; do
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
           "$WORKDIR/"ai-feature-*.deb \
           "$WORKDIR/unifi-access.deb" \
           "$WORKDIR/packages.txt"
fi

echo ""
