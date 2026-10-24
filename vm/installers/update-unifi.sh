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
#   ./update-unifi.sh --sync-os      # Sync UniFi OS packages to the newest firmware on OS_TRACK
#   ./update-unifi.sh --protect      # Upgrade Protect to latest stable
#   ./update-unifi.sh --protect-edge # Upgrade Protect to latest edge
#   ./update-unifi.sh --access       # Upgrade Access to latest stable
#   ./update-unifi.sh --access-edge  # Upgrade Access to latest edge
#   ./update-unifi.sh --all          # Sync OS + Protect + Access to stable
#   ./update-unifi.sh --all-edge     # Sync OS + Protect + Access to edge
#   ./update-unifi.sh --yes          # Skip confirmation prompts
#   ./update-unifi.sh --verify       # Check the storage/shim invariants (read-only)
#   ./update-unifi.sh --os-track 5.1 # Follow a release line (see OS_TRACK)
#
# Environment overrides (rarely needed):
#   OS_TRACK            - Which UNVR firmware --sync-os follows: a major (5),
#                         major.minor (5.1), an exact release (5.1.33), or
#                         'latest' (the API's newest, any major). Default:
#                         the major built on this system's Debian release
#                         (bullseye -> 5). UniFi OS 6.0 is Debian 13, so it
#                         is never pulled onto a Debian 11 VM by default.
#   DEB_PLATFORM        - App deb platform, default from /etc/os-release
#                         (Debian 11 -> uos-deb11-arm64)
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

# Directory this script lives in — used to locate sibling installers
# (install-shims.sh, install-storage.sh) for post-sync-os shim reconciliation.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROTECT_CHANNEL="${PROTECT_CHANNEL:-release}"

# Ubiquiti firmware API endpoints. firmware-latest answers with the newest
# build only; /api/firmware lists them (25 per page unless given a limit).
FW_API="https://fw-update.ubnt.com/api/firmware-latest"
FW_API_LIST="https://fw-update.ubnt.com/api/firmware"
FW_API_LIMIT=500

OS_TRACK="${OS_TRACK:-}"

# Default action
ACTION="check"
ASSUME_YES=0

# Set when --sync-os installed less than the firmware carries; the script
# then exits non-zero after the report and cleanup.
SYNC_INCOMPLETE=0

###############################################################################
# VERSION AND PLATFORM HELPERS
#
# UniFi OS 6.0 rebased the UNVR firmware from Debian 11 (bullseye) onto
# Debian 13 (trixie). Its Ubiquiti debs need glibc >= 2.38, libssl3t64 and
# libstdc++6 >= 14, so they cannot be installed on a Debian 11 VM, and the
# app debs (Protect, Access, ms ...) are published per base: uos-deb11-arm64
# and uos-deb13-arm64. These helpers keep the firmware, the app platform
# and the running system on the same Debian release.
# See docs/unifi-os-6-compat.md.
###############################################################################

# "UNVR4.al324.v5.1.33.44ce47b.260909.0025" (/usr/lib/version) and
# "v5.1.33+44ce47b" (the firmware API) both -> "5.1.33"; empty if neither.
os_version_of() {
    printf '%s\n' "${1:-}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 | cut -c2- || true
}

# One field ($2) of an os-release file ($1), unquoted; empty if absent.
os_release_field() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1 | tr -d "\"'" || true
}

# The os-release of an unpacked firmware root. Its etc/os-release is a link
# to ../usr/lib/os-release; read the target directly so a link can never
# resolve against this system's /usr instead.
fw_os_release() {
    if [ -f "$1/usr/lib/os-release" ]; then
        echo "$1/usr/lib/os-release"
    else
        echo "$1/etc/os-release"
    fi
}

# App deb platform for a Debian major version. Only 11 and 13 are published
# (uos-deb12-arm64 answers with nothing); anything else -> uos-deb11-arm64,
# the platform of UniFi OS 5.x.
uos_deb_platform() {
    case "${1:-}" in
        13) echo uos-deb13-arm64 ;;
        *)  echo uos-deb11-arm64 ;;
    esac
}

# Default OS_TRACK for a Debian codename: the UniFi OS major built on it.
os_track_for_debian() {
    case "${1:-}" in
        bullseye) echo 5 ;;
        trixie)   echo 6 ;;
        *)        echo latest ;;
    esac
}

# /api/firmware filters for a track: 5 | 5.1 | 5.1.33. "latest" has none.
# Fails on anything else.
os_track_filters() {
    local t="${1:-}"
    [ "$t" = latest ] && return 0
    [[ "$t" =~ ^([0-9]+)(\.([0-9]+))?(\.([0-9]+))?$ ]] || return 1
    printf '&filter=eq~~version_major~~%s' "${BASH_REMATCH[1]}"
    [ -z "${BASH_REMATCH[3]:-}" ] \
        || printf '&filter=eq~~version_minor~~%s' "${BASH_REMATCH[3]:-}"
    [ -z "${BASH_REMATCH[5]:-}" ] \
        || printf '&filter=eq~~version_patch~~%s' "${BASH_REMATCH[5]:-}"
    return 0
}

# Newest build in a firmware-latest answer or an /api/firmware listing
# (stdin), printed the way get_latest_version prints one; nothing if there
# is none. Sorted numerically (the listing comes unordered), ties broken by
# creation time.
pick_newest_firmware() {
    jq -r '[._embedded.firmware[]? | select(.version_major != null)]
        | sort_by(.version_major, .version_minor, .version_patch, .created) | last
        | if . == null then empty else {
            version: .version,
            url: ._links.data.href,
            sha256: .sha256_checksum,
            size: .file_size
          } end'
}

# The newest UNVR release on OS_TRACK ($1), printed like get_latest_version.
# 'latest' is the firmware-latest query this script always used. A track
# asks firmware-latest with the version filters first, so the server's own
# pick (staged rollouts included) wins; the full listing is the fallback.
# Uses api_get and get_latest_version from HELPERS below, at call time.
get_os_firmware() {
    local track="$1" filters query response picked n
    if [ "$track" = latest ]; then
        get_latest_version "unifi-nvr" "release" "$PLATFORM"
        return
    fi
    if ! filters="$(os_track_filters "$track")"; then
        echo "ERROR: OS_TRACK '$track' is not 'latest', 5, 5.1 or 5.1.33" >&2
        return 1
    fi
    query="filter=eq~~product~~unifi-nvr&filter=eq~~channel~~release"
    query="${query}&filter=eq~~platform~~${PLATFORM}${filters}"
    response=$(api_get "${FW_API}?${query}" || true)
    picked=$(echo "$response" | pick_newest_firmware 2>/dev/null || true)
    if [ -n "$picked" ]; then
        echo "$picked"
        return 0
    fi
    response=$(api_get "${FW_API_LIST}?${query}&limit=${FW_API_LIMIT}")
    if [ -z "$response" ]; then
        echo "ERROR: Failed to query API for unifi-nvr on track $track" >&2
        return 1
    fi
    if ! n=$(echo "$response" | jq -e '._embedded.firmware | length' 2>/dev/null); then
        echo "ERROR: unexpected answer from the firmware API for track $track" >&2
        return 1
    fi
    if [ "$n" -ge "$FW_API_LIMIT" ]; then
        echo "WARNING: the firmware listing hit its limit ($n);" \
             "the newest build may be missing" >&2
    fi
    echo "$response" | pick_newest_firmware
}

# 0 if firmware version $1 belongs to the UniFi OS line built on Debian
# codename $2 (bullseye: 5.x, trixie: 6.x), or if that is unknown either way.
# Otherwise say so and return 1. Lets --sync-os refuse before the snapshot
# and the download; fw_debian_matches stays as the check on the image itself.
fw_line_matches_debian() {
    local short line
    short="$(os_version_of "${1:-}")"
    line="$(os_track_for_debian "${2:-}")"
    if [ -z "$short" ] || [ "$line" = latest ] || [ "${short%%.*}" = "$line" ]; then
        return 0
    fi
    echo "ERROR: UniFi OS $short is not the $line.x line built on Debian" \
         "'${2:-}': its packages cannot be installed here. Nothing was" \
         "downloaded. See docs/unifi-os-6-compat.md." >&2
    return 1
}

# 0 if the unpacked firmware root $1 is built on Debian codename $2 (this
# system's); otherwise say why and return 1.
fw_debian_matches() {
    local fw_debian
    fw_debian="$(os_release_field "$(fw_os_release "$1")" VERSION_CODENAME)"
    if [ -n "$fw_debian" ] && [ "$fw_debian" = "${2:-}" ]; then
        return 0
    fi
    echo "ERROR: UNVR firmware ${FW_VERSION:-} is built on Debian" \
         "'${fw_debian:-unknown}'; this system runs Debian '${2:-unknown}'." >&2
    echo "       Its packages cannot be installed here; nothing was stopped" >&2
    echo "       or installed." >&2
    echo "       Stay on this base with OS_TRACK (default: the major for" >&2
    echo "       this Debian release); see docs/unifi-os-6-compat.md." >&2
    return 1
}

# Firmware packages --sync-os never installs: the UNVR kernel and initramfs,
# and the bundled apps that upgrade_protect / upgrade_access own.
sync_skips_package() {
    case "$1" in
        linux-image-*|unvr-initramfs|unifi-protect|ai-feature-*|unifi-access) return 0 ;;
    esac
    return 1
}

# 0 if every package --sync-os offered to apt is installed and configured
# ("ii") at the version the firmware root $1 carries. $2 lists the
# firmware's Ubiquiti packages (packages.txt); $3 is the repack directory:
# a package without a deb there failed to repack and was never offered.
fw_install_landed() {
    local root="$1" list="$2" debs="$3" pkg want have status bad=0
    while read -r pkg; do
        [ -n "$pkg" ] || continue
        sync_skips_package "$pkg" && continue
        compgen -G "$debs/${pkg}_*.deb" >/dev/null || continue
        want="$(dpkg-query --admindir="$root/var/lib/dpkg/" -W -f='${Version}' \
            "$pkg" 2>/dev/null || true)"
        have="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
        status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || true)"
        if [ -n "$want" ] && [ "$have" = "$want" ] && [ "${status%% *}" = ii ]; then
            continue
        fi
        echo "ERROR: $pkg is '${have:-not installed}' (dpkg status" \
             "'${status%% *}'), the firmware carries '${want:-unknown}'." >&2
        bad=1
    done < "$list"
    if [ "$bad" = 1 ]; then
        echo "ERROR: the install did not complete." >&2
        return 1
    fi
    return 0
}

# A note when app $1 is newer for Debian 13 ($3) than for Debian 11 ($2):
# the sign that the deb11 line is falling behind. Silent otherwise.
platform_lag_note() {
    local a="${2#v}" b="${3#v}"
    [ -n "$a" ] && [ "$a" != null ] && [ -n "$b" ] && [ "$b" != null ] || return 0
    if dpkg --compare-versions "$b" gt "$a" 2>/dev/null; then
        echo "    WARNING: $1 $b is out for uos-deb13-arm64, deb11 has only $a."
        echo "    The Debian 11 line is falling behind; see docs/unifi-os-6-compat.md."
    fi
    return 0
}

DEB_PLATFORM="${DEB_PLATFORM:-$(uos_deb_platform "$(os_release_field /etc/os-release VERSION_ID)")}"

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
    # Patch A edits the snapshot unifi-core 5.1.x builds from `ustorage space
    # inspect`. unifi-core 6.x has neither the call nor the snapshot (its disk
    # list comes from the storage gRPC stream ustated-shim serves), so there
    # is nothing to patch. Same test as unifi-core-storage-patch.sh.
    if [ ! -f "$sj" ]; then
        _ck 1 "service.js present"
    elif grep -qF '"ustorage",["space","inspect"' "$sj" ||
         grep -qF 'disks:[],sdcards:[]}' "$sj"; then
        [ "$(grep -cF '["disk","inspect"]' "$sj" 2>/dev/null)" = 1 ]; _ck $? "service.js Patch A (disk list)"
    else
        _ck 0 "service.js Patch A not needed (no ustorage space-inspect snapshot)"
    fi
    # Patch B (the 5.1.110-era drive-detect gate) is obsolete: 5.1.117
    # refactored that code path away and unifi-core-storage-patch.sh no
    # longer applies it. Its marker is correctly absent -- do not report that
    # as a failure.
    head -3 /usr/bin/ustorage 2>/dev/null | grep -q 'ustorage-vm'; _ck $? "/usr/bin/ustorage is the VM shim"
    systemctl is-active --quiet ustated-shim.service;             _ck $? "ustated-shim.service active"
    ss -ltn 2>/dev/null | grep -q '127\.0\.0\.1:11052';           _ck $? "ustated-shim listening on :11052"
    { [ "$(systemctl is-enabled usd.service 2>/dev/null)" = masked ] &&
      [ "$(systemctl is-enabled ustated.service 2>/dev/null)" = masked ]; }; _ck $? "usd + ustated masked"
    if [ -e /lib/systemd/system/ufcd.service ] || [ -e /usr/lib/systemd/system/ufcd.service ]; then
        [ "$(systemctl is-enabled ufcd.service 2>/dev/null)" = masked ]; _ck $? "ufcd masked"
    fi
    if dpkg-query -W -f='${Status}' ubntnas 2>/dev/null | grep -q 'install ok installed'; then
        head -3 /usr/bin/ubntnas 2>/dev/null | grep -q 'ubntnas-vm-guard' &&
            [ -x /usr/bin/ubntnas.real ]; _ck $? "ubntnas firmware-update guard (UI Update refused)"
    fi
    grep -q 'UUUU' /proc/mdstat 2>/dev/null;                      _ck $? "md array [UUUU]"
    [ -s /var/run/anonymous_device_id ];                          _ck $? "anonymous_device_id present"
    printf "    versions: unifi-core=%s unifi-protect=%s node=%s\n" \
        "$(dpkg-query -W -f='${Version}' unifi-core 2>/dev/null || echo '?')" \
        "$(dpkg-query -W -f='${Version}' unifi-protect 2>/dev/null || echo '?')" \
        "$(node --version 2>/dev/null || echo '?')"
    set -e
    return $fail
}

# Sourced (vm/tests/test_unifi_os6_compat.sh does this for the helpers
# above): stop here, before anything runs.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

###############################################################################
# ARGUMENT PARSING
###############################################################################

while [ $# -gt 0 ]; do
    case "$1" in
        --os-track)
            [ -n "${2:-}" ] || { echo "--os-track needs a value (5, 5.1, 5.1.33 or latest)"; exit 1; }
            OS_TRACK="$2"; shift ;;
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
            # The whole header: what it does, usage, environment (OS_TRACK ...).
            sed -n '2,/^# Run as root\./p' "$0" | sed 's/^# \?//'
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

# Remove the downloads and the extraction unless KEEP_WORKDIR=1. /opt may
# live on the small root partition: the firmware is about 800MB, the
# unpacked squashfs about 2.5GB, plus debs.
cleanup_workdir() {
    [ "${KEEP_WORKDIR:-0}" != "1" ] || return 0
    echo ""
    echo "Cleaning up $WORKDIR (set KEEP_WORKDIR=1 to retain)..."
    rm -rf "$WORKDIR/_fwupdate.bin"*extracted \
           "$WORKDIR/debs" \
           "$WORKDIR/fwupdate.bin" \
           "$WORKDIR/unifi-protect.deb" \
           "$WORKDIR/"ai-feature-*.deb \
           "$WORKDIR/unifi-access.deb" \
           "$WORKDIR/packages.txt"
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

# Every OTHER dependency of the Protect deb that the running system does not
# satisfy, as "<package> <op> <version>" lines (op/version absent if the
# dependency is unversioned).
#
# Protect 7.2 moved its media stack out of the UniFi OS firmware and into
# independently published debs: 7.2.105 depends on ms/msr/msp/mst >= 5.1.309,
# ds = 7.2.14, msf >= 0.0.7 and a new protect-verify >= 0.9.1 -- none of
# which firmware 5.1.25 carries, and all of which the firmware API publishes
# as their own products on the deb platform. Fetching only the ai-feature-*
# debs left apt with seven unmet dependencies and an aborted install
# (2026-08-21). Resolve them the same way the AI packages are resolved.
unmet_deps_of_deb() {
    # This script runs under `set -euo pipefail`, and this function runs
    # inside a process substitution, where an abort is SILENT. An unversioned
    # dependency makes `grep | head` exit non-zero; pipefail turns that into
    # a failed assignment; -e kills the function -- and the caller sees an
    # empty list and reports "(none)". That is exactly how the 2026-08-21
    # retry failed a second time. Relax the options for this function only
    # (`local -` restores them on return) and guard every probe.
    local -
    set +e +o pipefail
    local deb="$1" depends entry name op ver have cmp
    depends="$(dpkg-deb -f "$deb" Depends 2>/dev/null)" || return 0
    local IFS=','
    for entry in $depends; do
        entry="$(echo "$entry" | sed 's/|.*//')"        # first alternative
        name="$(echo "$entry" | grep -oE '[a-z0-9][a-z0-9.+-]+' | head -1)"
        [ -n "$name" ] || continue
        case "$name" in ai-feature-*) continue ;; esac   # handled above
        op="$(echo "$entry" | grep -oE '(>=|<=|>>|<<|=)' | head -1)"
        ver="$(echo "$entry" | grep -oE '[0-9][0-9a-zA-Z.+~:-]*' | head -1)"
        have="$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null)"
        if [ -n "$have" ]; then
            [ -n "$op" ] || continue                   # unversioned: satisfied
            case "$op" in
                ">=") cmp=ge ;; "<=") cmp=le ;; ">>") cmp=gt ;;
                "<<") cmp=lt ;; "=")  cmp=eq ;; *) cmp=ge ;;
            esac
            if dpkg --compare-versions "$have" "$cmp" "$ver"; then
                continue
            fi
        fi
        echo "$name $op $ver"
    done
    return 0
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

SYSTEM_DEBIAN="$(os_release_field /etc/os-release VERSION_CODENAME)"
OS_TRACK="${OS_TRACK:-$(os_track_for_debian "$SYSTEM_DEBIAN")}"
# Fatal only where the firmware is used: --protect, --access and --check
# carry on with the OS line unknown.
if ! FW_INFO=$(get_os_firmware "$OS_TRACK") || [ -z "$FW_INFO" ]; then
    case "$ACTION" in
        sync-os|all)
            echo "ERROR: no UNVR release on OS_TRACK=$OS_TRACK" >&2
            exit 1 ;;
    esac
    echo "WARNING: no UNVR release on OS_TRACK=$OS_TRACK; UniFi OS is not compared." >&2
    FW_INFO='{}'
fi
# The API's newest build, any major, to say so when the track excludes it.
FW_NEWEST_VERSION=$(get_latest_version "unifi-nvr" "release" "$PLATFORM" \
    2>/dev/null | jq -r '.version' 2>/dev/null || true)
PROTECT_INFO=$(get_latest_version "unifi-protect" "$PROTECT_CHANNEL" "$DEB_PLATFORM")
ACCESS_INFO=$(get_latest_version "unifi-access" "$PROTECT_CHANNEL" "$DEB_PLATFORM")
# On deb11, the same apps' deb13 builds: the day Debian 13 gets a newer
# Protect or Access than Debian 11, the deb11 line is ending.
PROTECT_DEB13_VERSION="" ACCESS_DEB13_VERSION=""
if [ "$DEB_PLATFORM" = uos-deb11-arm64 ]; then
    PROTECT_DEB13_VERSION=$(get_latest_version "unifi-protect" "$PROTECT_CHANNEL" \
        uos-deb13-arm64 2>/dev/null | jq -r '.version' 2>/dev/null || true)
    ACCESS_DEB13_VERSION=$(get_latest_version "unifi-access" "$PROTECT_CHANNEL" \
        uos-deb13-arm64 2>/dev/null | jq -r '.version' 2>/dev/null || true)
fi

FW_VERSION=$(echo "$FW_INFO" | jq -r '.version // empty')
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

# Compare UniFi OS as X.Y.Z: /usr/lib/version and the API spell it
# differently, so the raw strings never matched.
CURRENT_OS_SHORT="$(os_version_of "$CURRENT_OS_VERSION")"

echo ""
echo "Current versions:"
FW_SHORT="$(os_version_of "$FW_VERSION")"
if [ -n "$FW_SHORT" ]; then
    print_version "UniFi OS"      "${CURRENT_OS_SHORT:-$CURRENT_OS_VERSION}" "$FW_SHORT"
else
    printf "    %-30s %s (not compared: no firmware on this track)\n" \
        "UniFi OS" "${CURRENT_OS_SHORT:-$CURRENT_OS_VERSION}"
fi
# dpkg says 7.3.70, the API v7.3.70: compare without the v.
print_version "unifi-protect"     "$CURRENT_PROTECT"    "${PROTECT_VERSION#v}"
print_version "unifi-access"      "$CURRENT_ACCESS"     "${ACCESS_VERSION#v}"
echo "    ai-feature package         resolved from Protect at install"
echo "    (Other packages compared during sync)"
echo ""
echo "Channel: $PROTECT_CHANNEL"
echo "OS track: $OS_TRACK (Debian ${SYSTEM_DEBIAN:-unknown}, apps from $DEB_PLATFORM)"
if [ -n "$FW_NEWEST_VERSION" ] && [ "$FW_NEWEST_VERSION" != "null" ] &&
   [ "$(os_version_of "$FW_NEWEST_VERSION")" != "$(os_version_of "$FW_VERSION")" ]; then
    echo "    Newest UNVR firmware is $FW_NEWEST_VERSION, outside this track:"
    echo "    not installed unless OS_TRACK allows it. A different major can"
    echo "    need a different Debian base (6.x does: docs/unifi-os-6-compat.md)."
fi
TRACK_FOR_DEBIAN="$(os_track_for_debian "$SYSTEM_DEBIAN")"
if ! fw_line_matches_debian "$FW_VERSION" "$SYSTEM_DEBIAN" 2>/dev/null; then
    echo "    WARNING: UniFi OS $FW_SHORT is not the $TRACK_FOR_DEBIAN.x line built on"
    echo "    Debian $SYSTEM_DEBIAN; --sync-os and --all will refuse it."
fi
platform_lag_note unifi-protect "$PROTECT_VERSION" "$PROTECT_DEB13_VERSION"
platform_lag_note unifi-access "$ACCESS_VERSION" "$ACCESS_DEB13_VERSION"
if [ -n "$CURRENT_OS_SHORT" ] && [ -n "$FW_SHORT" ] &&
   dpkg --compare-versions "$FW_SHORT" lt "$CURRENT_OS_SHORT" 2>/dev/null; then
    echo "    NOTE: $FW_SHORT is older than the installed $CURRENT_OS_SHORT;"
    echo "    --sync-os would downgrade."
fi
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

    # The firmware's packages are built for its own Debian release. On a
    # mismatch (6.0.x is trixie, this VM may be bullseye) apt refuses the
    # whole set; before this check the script carried on, stamped
    # /usr/lib/version with the new release anyway and restarted the
    # stack, so the console reported a version it was not running.
    # Refuse here, before anything is stopped.
    if ! fw_debian_matches "$sqfs_root" "$SYSTEM_DEBIAN"; then
        cleanup_workdir
        return 1
    fi

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
        # Skip packages we won't install on VMs, and the app packages the
        # firmware bundles (removed below; upgrade_protect/upgrade_access
        # own them). Counting those made every sync of the release already
        # installed list phantom "downgrades" of Protect and its AI package
        # and restart the whole stack for nothing.
        sync_skips_package "$pkg" && continue
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
    # Only when the install landed. apt's exit code cannot tell (the
    # mtd-utils hook error above fails good runs too); every repacked
    # package installed at the firmware's version can. unifi-core and the
    # stack read this file and report it as the console's firmware version.
    if fw_install_landed "$sqfs_root" "$WORKDIR/packages.txt" "$WORKDIR/debs"; then
        cp "$sqfs_root/usr/lib/version" /usr/lib/version
        echo "    System version is now: $(cat /usr/lib/version)"
    else
        echo "       /usr/lib/version left at: $(cat /usr/lib/version 2>/dev/null)" >&2
        SYNC_INCOMPLETE=1
    fi

    echo ""
    echo ">>> Masking VM-incompatible services..."
    # These services expect real UNVR hardware and fail on VMs.
    # Mask (not just disable) because they're triggered as dependencies
    # of other services regardless of whether they're enabled. ustated is
    # masked too — the ustated-shim replaces it.
    # ufcd (fan control, new in 6.0's ustd, Restart=always) wants usdbd and
    # the UNVR fans; on a VM it can only fail and be restarted. Masking it
    # where it does not exist yet (5.x) is harmless.
    for svc in usd usdbd rpsd uhwd sfp sfpd ustated ufcd; do
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

    # Anything else Protect needs that the system lacks: try the firmware
    # API for it on the deb platform. What the API does not publish is left
    # to apt, which then reports it plainly.
    echo ""
    echo ">>> Resolving Protect's other unmet dependencies..."
    local dep_pkg dep_op dep_ver dep_info dep_url dep_ver_avail dep_sha
    local n_dep=0
    while read -r dep_pkg dep_op dep_ver; do
        [ -n "$dep_pkg" ] || continue
        echo "    Protect $PROTECT_VERSION needs: $dep_pkg $dep_op $dep_ver"
        if ! dep_info="$(get_latest_version "$dep_pkg" "$PROTECT_CHANNEL" \
                         "$DEB_PLATFORM" 2>/dev/null)" \
           || [ "$(echo "$dep_info" | jq -r '.url')" = "null" ]; then
            echo "    (not published on the firmware API -- leaving to apt)"
            continue
        fi
        dep_ver_avail="$(echo "$dep_info" | jq -r '.version')"
        dep_sha="$(echo "$dep_info" | jq -r '.sha256')"
        dep_url="$(echo "$dep_info" | jq -r '.url')"
        echo ">>> Downloading $dep_pkg ($dep_ver_avail)..."
        download_verified "$dep_url" "$WORKDIR/${dep_pkg}.deb" "$dep_sha"
        ai_debs+=("$WORKDIR/${dep_pkg}.deb")
        n_dep=$((n_dep + 1))
    done < <(unmet_deps_of_deb "$WORKDIR/unifi-protect.deb")
    [ "$n_dep" -gt 0 ] || echo "    (none)"

    # Best-effort heads-up about non-ai deps the system lacks (node24,
    # unifi-core ...). Those are installed by --sync-os from the firmware.
    preflight_protect_deps "$WORKDIR/unifi-protect.deb"

    echo ""
    echo ">>> Stopping services..."
    systemctl stop unifi-protect "${ai_pkgs[@]}" 2>/dev/null || true

    echo ""
    echo ">>> Installing..."
    unhold_ubiquiti_packages
    # If apt refuses, bring the OLD Protect straight back. On 2026-08-21 an
    # unmet-dependency abort left the service stopped -- recording down --
    # until someone noticed.
    if ! apt-get install -y --allow-downgrades --no-install-recommends \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        "$WORKDIR/unifi-protect.deb" "${ai_debs[@]}"; then
        echo "" >&2
        echo "ERROR: install failed -- restarting the existing Protect." >&2
        systemctl start unifi-protect "${ai_pkgs[@]}" 2>/dev/null || true
        return 1
    fi
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

    # dpkg reports "4.3.22+12152"; the API reports "v4.3.22+12152" -- strip
    # the v, as upgrade_protect does. Without it Access was reinstalled on
    # every run.
    if [ "$CURRENT_ACCESS" = "${ACCESS_VERSION#v}" ]; then
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
        fw_line_matches_debian "$FW_VERSION" "$SYSTEM_DEBIAN" || exit 1
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
        fw_line_matches_debian "$FW_VERSION" "$SYSTEM_DEBIAN" || exit 1
        recommend_snapshot "sync UniFi OS + upgrade Protect + upgrade Access"
        sync_os_packages
        # Apps on a half-synced OS would only compound it: report and stop.
        if [ "$SYNC_INCOMPLETE" = "1" ]; then
            echo ""
            echo ">>> Skipping the Protect and Access upgrades: the OS sync is incomplete."
        else
            upgrade_protect
            upgrade_access
        fi
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

cleanup_workdir

echo ""
if [ "$SYNC_INCOMPLETE" = "1" ]; then
    echo "UniFi OS sync INCOMPLETE: unifi-core did not reach the firmware's"
    echo "version (see the ERROR above). /usr/lib/version was not changed."
    exit 1
fi
