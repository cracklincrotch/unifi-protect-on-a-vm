#!/bin/bash
# Tests for the UniFi OS 6.0 compatibility changes (docs/unifi-os-6-compat.md).
# Linux, no root, no VM, no network: every system command the code under test
# could reach is a stub on PATH, and the firmware is replaced by fixtures.
#
#   update-unifi.sh               version / track / platform helpers, the
#                                 firmware pick, the Debian line and image
#                                 guards, the install-landed check, the ufcd
#                                 mask, the deb11/deb13 lag note, --help
#   install-protect-baremetal.sh  fw_api_href, the track block, its guard,
#                                 the ufcd mask, the platform
#   unifi-core-storage-patch.sh   5.1 patch, 6.0 no-op, anchor-drift alert
#   ustorage                      worm check, unknown verbs
#   ubntnas guard                 refuses `system upgrade`, passes the rest
#
# Needs bash, python3 and jq. Written for Linux; it also runs on macOS
# (checks that need dpkg are skipped there).
#
# usage: vm/tests/test_unifi_os6_compat.sh
#        FW_ROOT_51=<5.1.33 squashfs-root> FW_ROOT_60=<6.0.11 squashfs-root> \
#            vm/tests/test_unifi_os6_compat.sh
#   The second form also runs the patch script and the Debian guard against
#   the real unpacked firmware (read-only: service.js is copied first).
# shellcheck disable=SC1090,SC2034  # update-unifi.sh is sourced by path; it reads FW_API_LIMIT
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
VM="$(cd "$HERE/.." && pwd)"
UPD="$VM/installers/update-unifi.sh"
INST="$VM/installers/install-protect-baremetal.sh"
PATCH="$VM/storage/rootfs/usr/local/bin/unifi-core-storage-patch.sh"
UST="$VM/storage/rootfs/usr/bin/ustorage"
GUARD="$VM/wrappers/rootfs/usr/bin/ubntnas"
SHIMS="$VM/installers/install-shims.sh"
T=$(mktemp -d /tmp/os6test.XXXX)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; echo "$2" | head -8 | sed 's/^/      /'; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$3"; fi; }

# Stubs: anything that would touch the system records the call and fails.
mkdir -p "$T/bin"
for c in apt-get systemctl wget curl mount umount dpkg-repack binwalk logger; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 1\n' "$c" "$T" > "$T/bin/$c"
    chmod +x "$T/bin/$c"
done
# logger succeeds (the patch script's alert path uses it).
printf '#!/bin/sh\necho "logger $*" >> "%s/calls"\nexit 0\n' "$T" > "$T/bin/logger"
export PATH="$T/bin:$PATH"
calls() { cat "$T/calls" 2>/dev/null; }
reset_calls() { : > "$T/calls"; }

# Run a command with update-unifi.sh sourced (its helpers, nothing else).
upd() { ( source "$UPD" && "$@" ); }

###############################################################################
# update-unifi.sh: sourcing
###############################################################################
# Without its sourced-return guard, sourcing would run the real script (as
# root it would reach the network and apt). Check the guard statically first.
gl=$(grep -nF 'if [ "${BASH_SOURCE[0]}" != "$0" ]; then' "$UPD" | head -1 | cut -d: -f1)
pl=$(grep -nF '# ARGUMENT PARSING' "$UPD" | head -1 | cut -d: -f1)
if [ -z "$gl" ] || [ -z "$pl" ] || [ "$gl" -gt "$pl" ]; then
    echo "FAIL  update-unifi.sh has no sourced-return guard before ARGUMENT PARSING;"
    echo "      not sourcing it. Nothing else can run."
    exit 1
fi
reset_calls
out=$( ( source "$UPD"; echo "sourced rc=$?" ) 2>&1 )
check "sourcing update-unifi.sh runs nothing and returns 0" \
    'grep -q "sourced rc=0" <<<"$out" && [ -z "$(calls)" ]' "$out
$(calls)"

###############################################################################
# update-unifi.sh: version and platform helpers
###############################################################################
check "os_version_of reads /usr/lib/version (5.1.33)" \
    '[ "$(upd os_version_of UNVR4.al324.v5.1.33.44ce47b.260909.0025)" = 5.1.33 ]' ""
check "os_version_of reads /usr/lib/version (6.0.11)" \
    '[ "$(upd os_version_of UNVR4.al324.v6.0.11.dd9ab55.260930.0750)" = 6.0.11 ]' ""
check "os_version_of reads the API spelling" \
    '[ "$(upd os_version_of v6.0.11+dd9ab55)" = 6.0.11 ]' ""
out=$(upd os_version_of unknown; echo "rc=$?")
check "os_version_of: no version -> empty, rc 0 under set -e" '[ "$out" = "rc=0" ]' "$out"

printf 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nVERSION_ID="13"\nVERSION_CODENAME=trixie\n' > "$T/os-release-13"
check "os_release_field: unquoted value" \
    '[ "$(upd os_release_field "$T/os-release-13" VERSION_CODENAME)" = trixie ]' ""
check "os_release_field: quoted value" \
    '[ "$(upd os_release_field "$T/os-release-13" VERSION_ID)" = 13 ]' ""
out=$(upd os_release_field "$T/missing" VERSION_ID; echo "rc=$?")
check "os_release_field: missing file -> empty, rc 0" '[ "$out" = "rc=0" ]' "$out"

mkroot() {  # mkroot <dir> <codename>: a firmware root as the squashfs lays it out
    mkdir -p "$1/usr/lib" "$1/etc" "$1/var/lib/dpkg"
    printf 'VERSION_CODENAME=%s\n' "$2" > "$1/usr/lib/os-release"
    ln -sf ../usr/lib/os-release "$1/etc/os-release"
}
mkroot "$T/fw60" trixie
mkroot "$T/fw51" bullseye
mkdir -p "$T/fwabs/usr/lib" "$T/fwabs/etc"
printf 'VERSION_CODENAME=trixie\n' > "$T/fwabs/usr/lib/os-release"
ln -sf /nonexistent/os-release "$T/fwabs/etc/os-release"
check "fw_os_release reads usr/lib/os-release, not an absolute etc link" \
    '[ "$(upd fw_os_release "$T/fwabs")" = "$T/fwabs/usr/lib/os-release" ]' ""
mkdir -p "$T/fwetc/etc"; printf 'VERSION_CODENAME=bullseye\n' > "$T/fwetc/etc/os-release"
check "fw_os_release falls back to etc/os-release" \
    '[ "$(upd fw_os_release "$T/fwetc")" = "$T/fwetc/etc/os-release" ]' ""

check "uos_deb_platform 11 -> uos-deb11-arm64" '[ "$(upd uos_deb_platform 11)" = uos-deb11-arm64 ]' ""
check "uos_deb_platform 13 -> uos-deb13-arm64" '[ "$(upd uos_deb_platform 13)" = uos-deb13-arm64 ]' ""
check "uos_deb_platform unknown -> uos-deb11-arm64" \
    '[ "$(upd uos_deb_platform "")" = uos-deb11-arm64 ] && [ "$(upd uos_deb_platform x)" = uos-deb11-arm64 ]' ""
check "uos_deb_platform 12 (unpublished) -> uos-deb11-arm64" '[ "$(upd uos_deb_platform 12)" = uos-deb11-arm64 ]' ""

check "os_track_for_debian bullseye -> 5" '[ "$(upd os_track_for_debian bullseye)" = 5 ]' ""
check "os_track_for_debian trixie -> 6" '[ "$(upd os_track_for_debian trixie)" = 6 ]' ""
check "os_track_for_debian unknown -> latest" '[ "$(upd os_track_for_debian bookworm)" = latest ]' ""

check "os_track_filters 5" \
    '[ "$(upd os_track_filters 5)" = "&filter=eq~~version_major~~5" ]' "$(upd os_track_filters 5)"
check "os_track_filters 5.1" \
    '[ "$(upd os_track_filters 5.1)" = "&filter=eq~~version_major~~5&filter=eq~~version_minor~~1" ]' "$(upd os_track_filters 5.1)"
check "os_track_filters 5.1.33" \
    '[ "$(upd os_track_filters 5.1.33)" = "&filter=eq~~version_major~~5&filter=eq~~version_minor~~1&filter=eq~~version_patch~~33" ]' "$(upd os_track_filters 5.1.33)"
out=$(upd os_track_filters latest; echo "rc=$?")
check "os_track_filters latest -> no filter, rc 0" '[ "$out" = "rc=0" ]' "$out"
check "os_track_filters rejects 6.x and empty" \
    '! upd os_track_filters 6.x >/dev/null 2>&1 && ! upd os_track_filters "" >/dev/null 2>&1' ""

###############################################################################
# update-unifi.sh: picking the firmware for a track
###############################################################################
# Shape recorded from /api/firmware on 2026-10-24 (unordered, as the API
# returns it); URLs and hashes shortened. v5.1.9 is made up, to catch a
# string sort that would rank it above v5.1.33.
fwent() {  # fwent <major> <minor> <patch>
    printf '{"version":"v%s.%s.%s+abc","version_major":%s,"version_minor":%s,"version_patch":%s,' "$1" "$2" "$3" "$1" "$2" "$3"
    printf '"sha256_checksum":"sha-%s.%s.%s","file_size":1,"_links":{"data":{"href":"https://fw-download.ubnt.com/data/unifi-nvr/%s.%s.%s.bin"}}}' "$1" "$2" "$3" "$1" "$2" "$3"
}
listing() { local IFS=,; echo "{\"_embedded\":{\"firmware\":[$*]}}"; }
listing "$(fwent 5 1 31)" "$(fwent 5 0 16)" "$(fwent 5 1 33)" "$(fwent 5 1 9)" > "$T/list-5.json"
listing "$(fwent 5 1 33)" "$(fwent 6 0 11)" > "$T/list-any.json"
listing > "$T/list-empty.json"

out=$(upd pick_newest_firmware < "$T/list-5.json")
check "pick_newest_firmware sorts numerically: 5.1.33 beats 5.1.9 and 5.1.31" \
    '[ "$(jq -r .version <<<"$out")" = v5.1.33+abc ] && [ "$(jq -r .sha256 <<<"$out")" = sha-5.1.33 ] && [ "$(jq -r .url <<<"$out")" = https://fw-download.ubnt.com/data/unifi-nvr/5.1.33.bin ]' "$out"
out=$(upd pick_newest_firmware < "$T/list-any.json")
check "pick_newest_firmware: a higher major wins" '[ "$(jq -r .version <<<"$out")" = v6.0.11+abc ]' "$out"
out=$(upd pick_newest_firmware < "$T/list-empty.json"; echo "rc=$?")
check "pick_newest_firmware: empty listing -> nothing" '[ "$out" = "rc=0" ]' "$out"

# get_os_firmware with api_get / get_latest_version stubbed. The stub answers
# firmware-latest from $LATEST (default: the same file) and the listing
# from $LISTING.
gof() {  # gof <track> <listing file> [FW_API_LIMIT] [firmware-latest file]
    ( source "$UPD"
      [ -n "${3:-}" ] && FW_API_LIMIT=$3
      api_get() {
          echo "$1" >> "$T/urls"
          case "$1" in *firmware-latest*) cat "$LATEST" ;; *) cat "$LISTING" ;; esac
      }
      get_latest_version() { echo "get_latest_version $*" >> "$T/urls"; echo '{"version":"vLATEST"}'; }
      LISTING="$2" LATEST="${4:-$2}" get_os_firmware "$1" )
}
listing "$(fwent 5 1 33)" > "$T/latest-5.json"
: > "$T/urls"; out=$(gof 5.1 "$T/list-5.json" "" "$T/latest-5.json" 2>&1)
u=$(cat "$T/urls")
check "get_os_firmware 5.1 asks firmware-latest with the version filters first" \
    '[ "$(grep -c . <<<"$u")" = 1 ] && grep -q "/api/firmware-latest?filter=eq~~product~~unifi-nvr&filter=eq~~channel~~release&filter=eq~~platform~~UNVR&filter=eq~~version_major~~5&filter=eq~~version_minor~~1$" <<<"$u"' "$u"
check "get_os_firmware 5.1 returns the server's pick (5.1.33)" '[ "$(jq -r .version <<<"$out")" = v5.1.33+abc ]' "$out"
: > "$T/urls"; out=$(gof 5.1 "$T/list-5.json" "" "$T/list-empty.json" 2>&1)
u=$(cat "$T/urls")
check "get_os_firmware falls back to the listing, filtered and with a limit" \
    'grep -q "/api/firmware?.*version_major~~5&filter=eq~~version_minor~~1&limit=500" <<<"$u" && [ "$(jq -r .version <<<"$out")" = v5.1.33+abc ]' "$u
$out"
: > "$T/urls"; out=$(gof latest "$T/list-5.json" 2>&1)
check "get_os_firmware latest keeps the firmware-latest query" \
    'grep -q "get_latest_version unifi-nvr release UNVR" "$T/urls" && [ "$(jq -r .version <<<"$out")" = vLATEST ]' "$(cat "$T/urls")"
out=$(gof 6.x "$T/list-5.json" 2>&1); rc=$?
check "get_os_firmware rejects a bad track" '[ $rc != 0 ] && grep -q "is not .latest." <<<"$out"' "$out"
out=$(gof 5 "$T/list-5.json" 4 "$T/list-empty.json" 2>&1 >/dev/null)
check "get_os_firmware warns when the listing fills its limit" 'grep -q "hit its limit" <<<"$out"' "$out"
echo '<html>502 Bad Gateway</html>' > "$T/list-html.json"
out=$(gof 5 "$T/list-html.json" 2>&1); rc=$?
check "get_os_firmware: a non-JSON answer is a clear error" \
    '[ $rc != 0 ] && grep -q "unexpected answer from the firmware API" <<<"$out" && ! grep -q "integer expression" <<<"$out"' "$out"
# Two builds of one version: the later one wins.
twin() { fwent 5 1 33 | sed "s/sha-5.1.33/sha-$1/; s/\"file_size\"/\"created\":\"$2\",\"file_size\"/"; }
listing "$(twin new 2026-09-11T00:00:00Z)" "$(twin old 2026-09-10T00:00:00Z)" > "$T/list-twins.json"
check "pick_newest_firmware: a tie on version goes to the newer build" \
    '[ "$(upd pick_newest_firmware < "$T/list-twins.json" | jq -r .sha256)" = sha-new ]' "$(upd pick_newest_firmware < "$T/list-twins.json")"

# The Debian line check that refuses before the snapshot and the download.
out=$(upd fw_line_matches_debian v6.0.11+dd9ab55 bullseye 2>&1); rc=$?
check "fw_line_matches_debian: 6.0.11 on bullseye -> refused, nothing downloaded" \
    '[ $rc != 0 ] && grep -q "UniFi OS 6.0.11 is not the 5.x line built on Debian .bullseye." <<<"$out" && grep -q "Nothing was downloaded" <<<"$out"' "$out"
check "fw_line_matches_debian: 5.1.33 on bullseye, 6.0.11 on trixie -> fine" \
    'upd fw_line_matches_debian v5.1.33+44ce47b bullseye && upd fw_line_matches_debian v6.0.11+dd9ab55 trixie' ""
check "fw_line_matches_debian: unknown Debian or version -> no opinion" \
    'upd fw_line_matches_debian v6.0.11+dd9ab55 bookworm && upd fw_line_matches_debian "" bullseye' ""

# The deb11/deb13 lag note (dpkg --compare-versions; skipped without dpkg).
if command -v dpkg >/dev/null 2>&1; then
    out=$(upd platform_lag_note unifi-protect v7.3.70 v7.4.1)
    check "platform_lag_note: newer on deb13 -> warning" \
        'grep -q "unifi-protect 7.4.1 is out for uos-deb13-arm64, deb11 has only 7.3.70" <<<"$out"' "$out"
    check "platform_lag_note: same, older or unknown -> silent" \
        '[ -z "$(upd platform_lag_note unifi-access v4.3.22+12152 v4.3.22+12152)$(upd platform_lag_note a v2 v1)$(upd platform_lag_note a v2 null)$(upd platform_lag_note a v2 "")" ]' ""
fi

###############################################################################
# update-unifi.sh: the Debian guard and the install-landed check
###############################################################################
out=$(FW_VERSION=v6.0.11+dd9ab55 upd fw_debian_matches "$T/fw60" bullseye 2>&1); rc=$?
check "fw_debian_matches refuses trixie firmware on bullseye" \
    '[ $rc != 0 ] && grep -q "v6.0.11+dd9ab55 is built on Debian .trixie.; this system runs Debian .bullseye." <<<"$out"' "$out"
out=$(upd fw_debian_matches "$T/fw51" bullseye 2>&1); rc=$?
check "fw_debian_matches accepts bullseye firmware on bullseye" '[ $rc = 0 ] && [ -z "$out" ]' "$out"
out=$(upd fw_debian_matches "$T/fw60" trixie 2>&1); rc=$?
check "fw_debian_matches accepts trixie firmware on trixie" '[ $rc = 0 ]' "$out"
mkdir -p "$T/fwnone"
out=$(upd fw_debian_matches "$T/fwnone" bullseye 2>&1); rc=$?
check "fw_debian_matches refuses a root without os-release" '[ $rc != 0 ] && grep -q "Debian .unknown." <<<"$out"' "$out"

# dpkg-query stub: --admindir answers from $T/fwdb, otherwise from $T/sysdb
# ("<package> <version> <status>" lines; the status is what the guest's
# dpkg prints for ${db:Status-Abbrev}).
cat > "$T/bin/dpkg-query" <<EOF
#!/bin/sh
for last; do :; done
case "\$*" in *--admindir*) db="$T/fwdb" ;; *) db="$T/sysdb" ;; esac
line=\$(grep "^\$last " "\$db") || exit 1
case "\$*" in
    *Status-Abbrev*) printf '%s ' "\$(echo "\$line" | cut -d' ' -f3)" ;;
    *)               printf '%s' "\$(echo "\$line" | cut -d' ' -f2)" ;;
esac
EOF
chmod +x "$T/bin/dpkg-query"
mkdir -p "$T/debs"
printf 'unifi-core\nustd \nubnt-tools\nunvr-al324-base-files\nunifi-protect\nlinux-image-4.19.152-alpine-unvr\n' > "$T/packages.txt"
for d in unifi-core_6.0.123 ustd_6.0.9 ubnt-tools_6.0.20 unifi-protect_7.2.105; do : > "$T/debs/${d}_arm64.deb"; done
printf 'unifi-core 6.0.123 ii\nustd 6.0.9 ii\nubnt-tools 6.0.20 ii\nunvr-al324-base-files 6.0.102 ii\nunifi-protect 7.2.105 ii\n' > "$T/fwdb"
landed() { upd fw_install_landed "$T/fw60" "$T/packages.txt" "$T/debs" 2>&1; }
printf 'unifi-core 6.0.123 ii\nustd 6.0.9 ii\nubnt-tools 6.0.20 ii\nunvr-al324-base-files 5.1.144 ii\nunifi-protect 7.3.70 ii\n' > "$T/sysdb"
out=$(landed); rc=$?
check "fw_install_landed: every repacked package at the firmware's version -> landed" \
    '[ $rc = 0 ] && [ -z "$out" ]' "$out"
check "fw_install_landed: a failed repack and the skipped packages are not counted" \
    '[ $rc = 0 ]' "$out"
printf 'unifi-core 6.0.123 ii\nustd 5.1.18 ii\nubnt-tools 6.0.20 ii\n' > "$T/sysdb"
out=$(landed); rc=$?
check "fw_install_landed: one package left behind -> refuse, and name it" \
    '[ $rc != 0 ] && grep -q "ustd is .5.1.18. (dpkg status .ii.), the firmware carries .6.0.9." <<<"$out" && grep -q "the install did not complete" <<<"$out" && ! grep -q "unifi-core is" <<<"$out"' "$out"
printf 'unifi-core 6.0.123 ii\nustd 6.0.9 ii\nubnt-tools 6.0.20 iF\n' > "$T/sysdb"
out=$(landed); rc=$?
check "fw_install_landed: right version but half-configured -> refuse" \
    '[ $rc != 0 ] && grep -q "ubnt-tools is .6.0.20. (dpkg status .iF.)" <<<"$out"' "$out"
printf 'ustd 6.0.9 ii\nubnt-tools 6.0.20 ii\n' > "$T/sysdb"
out=$(landed); rc=$?
check "fw_install_landed: a package missing on the system -> refuse" \
    '[ $rc != 0 ] && grep -q "unifi-core is .not installed." <<<"$out"' "$out"
rm -f "$T/bin/dpkg-query"

# How sync_os_packages and the action dispatch use them (order, not runs).
fn_line() { grep -nF "$1" "$UPD" | head -1 | cut -d: -f1; }
check "sync_os_packages: Debian guard comes before services are stopped" \
    '[ "$(fn_line "if ! fw_debian_matches")" -lt "$(fn_line ">>> Stopping services...")" ] && [ "$(fn_line "if ! fw_debian_matches")" -gt "$(fn_line "sync_os_packages() {")" ]' ""
check "sync_os_packages: /usr/lib/version is copied only after fw_install_landed" \
    'grep -A1 "if fw_install_landed" "$UPD" | grep -qF "cp \"\$sqfs_root/usr/lib/version\" /usr/lib/version" && [ "$(grep -cF "/usr/lib/version\" /usr/lib/version" "$UPD")" = 1 ]' ""
check "sync_os_packages: the version diff skips the bundled app packages" \
    'upd sync_skips_package unifi-protect && upd sync_skips_package ai-feature-controller && upd sync_skips_package unifi-access && upd sync_skips_package linux-image-4.19.152-alpine-unvr && upd sync_skips_package unvr-initramfs && ! upd sync_skips_package unifi-core && [ "$(grep -c "sync_skips_package \"\$pkg\" && continue" "$UPD")" = 2 ]' ""
check "sync-os and --all refuse another Debian's line before the snapshot" \
    '[ "$(grep -B1 "recommend_snapshot \"sync UniFi OS" "$UPD" | grep -c "fw_line_matches_debian \"\$FW_VERSION\" \"\$SYSTEM_DEBIAN\" || exit 1")" = 2 ]' "$(grep -B1 "recommend_snapshot \"sync UniFi OS" "$UPD")"
check "a bad or empty OS_TRACK is fatal only for --sync-os and --all" \
    'grep -A3 "if ! FW_INFO=\$(get_os_firmware" "$UPD" | grep -q "sync-os|all)"' ""
out=$(bash "$UPD" --help 2>&1); rc=$?
check "--help shows the usage and OS_TRACK" \
    '[ $rc = 0 ] && grep -q -- "--os-track 5.1" <<<"$out" && grep -q "OS_TRACK            - Which UNVR firmware" <<<"$out"' "$out"
check "--all skips the app upgrades when the OS sync is incomplete" \
    'grep -A3 "sync_os_packages$" "$UPD" | grep -q "SYNC_INCOMPLETE"' ""

###############################################################################
# Static checks on both installers
###############################################################################
check "update-unifi.sh masks ufcd with the other hardware daemons" \
    'grep -qE "for svc in usd usdbd rpsd uhwd sfp sfpd ustated ufcd; do" "$UPD"' ""
check "install-protect-baremetal.sh masks ufcd with the other hardware daemons" \
    'grep -qE "for svc in usd usdbd rpsd uhwd sfp sfpd ufcd; do" "$INST"' ""
check "install-protect-baremetal.sh: app queries follow DEB_PLATFORM" \
    '! grep -q "platform~~uos-deb11-arm64" "$INST" && [ "$(grep -c "platform~~\${DEB_PLATFORM}" "$INST")" = 2 ]' \
    "$(grep -n "platform~~" "$INST")"
gl=$(grep -nF 'if [ "${BASH_SOURCE[0]}" != "$0" ]; then' "$UPD" | head -1 | cut -d: -f1)
rl=$(grep -nF 'if [ "$(id -u)" -ne 0 ]; then' "$UPD" | head -1 | cut -d: -f1)
check "update-unifi.sh: the sourced guard comes before the root check" \
    '[ -n "$gl" ] && [ -n "$rl" ] && [ "$gl" -lt "$rl" ]' "guard at line $gl, root check at line $rl"

###############################################################################
# install-protect-baremetal.sh: fw_api_href picks the newest build
###############################################################################
eval "$(sed -n '/^fw_api_href() {/,/^}/p' "$INST")"
check "fw_api_href: one build (firmware-latest)" \
    '[ "$(listing "$(fwent 6 0 11)" | fw_api_href)" = https://fw-download.ubnt.com/data/unifi-nvr/6.0.11.bin ]' ""
check "fw_api_href: unordered listing -> newest, numerically" \
    '[ "$(fw_api_href < "$T/list-5.json")" = https://fw-download.ubnt.com/data/unifi-nvr/5.1.33.bin ]' "$(fw_api_href < "$T/list-5.json")"
check "fw_api_href: empty listing or bad JSON -> empty" \
    '[ -z "$(fw_api_href < "$T/list-empty.json")" ] && [ -z "$(echo nope | fw_api_href)" ]' ""

# The installer's OS_TRACK / DEB_PLATFORM block, run under its own strict
# mode against a fixture os-release instead of /etc/os-release.
printf 'VERSION_ID="11"\nVERSION_CODENAME=bullseye\n' > "$T/os-release-11"
printf 'VERSION_ID="12"\nVERSION_CODENAME=bookworm\n' > "$T/os-release-12"
INST_CFG="$(sed -n '/^OS_TRACK="\${OS_TRACK:-}"$/,/^PROTECT_UPDATE_URL=/p' "$INST")"
instcfg() {  # instcfg <os-release> [OS_TRACK]
    ( set -euo pipefail; DEVICE=UNVR; OS_TRACK="${2:-}"; unset DEB_PLATFORM
      eval "${INST_CFG//\/etc\/os-release/$1}"
      echo "$OS_TRACK|$DEB_PLATFORM|$FW_UPDATE_URL|$PROTECT_UPDATE_URL" )
}
check "installer: the config block was found" '[ "$(grep -c . <<<"$INST_CFG")" -gt 10 ]' "$INST_CFG"
out=$(instcfg "$T/os-release-11")
check "installer on bullseye: track 5, deb11, a version_major~~5 listing" \
    '[ "$(cut -d"|" -f1-2 <<<"$out")" = "5|uos-deb11-arm64" ] && grep -q "/api/firmware?.*platform~~UNVR&filter=eq~~version_major~~5&limit=500|" <<<"$out" && grep -q "platform~~uos-deb11-arm64$" <<<"$out"' "$out"
out=$(instcfg "$T/os-release-13")
check "installer on trixie: track 6, deb13" \
    '[ "$(cut -d"|" -f1-2 <<<"$out")" = "6|uos-deb13-arm64" ] && grep -q "version_major~~6&limit=500" <<<"$out"' "$out"
out=$(instcfg "$T/os-release-12")
check "installer on bookworm: track latest (firmware-latest), deb11" \
    '[ "$(cut -d"|" -f1-2 <<<"$out")" = "latest|uos-deb11-arm64" ] && grep -q "/api/firmware-latest?filter=eq~~product~~unifi-nvr" <<<"$out"' "$out"
out=$(instcfg "$T/os-release-11" 5.1.33)
check "installer: OS_TRACK=5.1.33 pins major, minor and patch" \
    'grep -q "version_major~~5&filter=eq~~version_minor~~1&filter=eq~~version_patch~~33&limit=500" <<<"$out"' "$out"
out=$(instcfg "$T/os-release-11" bogus 2>&1); rc=$?
check "installer: a bad OS_TRACK stops the install" '[ $rc != 0 ] && grep -q "is not .latest." <<<"$out"' "$out"

# The installer's Debian guard, in a scratch WORKDIR with a cached download.
INST_GUARD="$(sed -n '/^FW_OS_RELEASE="\$SQFS_ROOT\/usr\/lib\/os-release"$/,/^fi$/p' "$INST")"
instguard() {  # instguard <fw root> <system codename>
    mkdir -p "$T/inst/firmware-build"; echo bin > "$T/inst/firmware-build/fwupdate.bin"
    ( set -euo pipefail; WORKDIR="$T/inst"; SQFS_ROOT="$1"; OS_CODENAME="$2"
      eval "$INST_GUARD"; echo "guard passed" ) 2>&1
}
check "installer: the guard block was found" 'grep -q "exit 1" <<<"$INST_GUARD"' "$INST_GUARD"
out=$(instguard "$T/fw60" bullseye); rc=$?
check "installer guard: trixie firmware on bullseye stops, cached fwupdate.bin removed" \
    '[ $rc != 0 ] && grep -q "built on Debian .trixie." <<<"$out" && [ ! -e "$T/inst/firmware-build/fwupdate.bin" ]' "$out"
out=$(instguard "$T/fw51" bullseye); rc=$?
check "installer guard: bullseye firmware on bullseye passes, download kept" \
    '[ $rc = 0 ] && grep -q "guard passed" <<<"$out" && [ -e "$T/inst/firmware-build/fwupdate.bin" ]' "$out"
check "installer: the guard runs before /usr/lib/version is written" \
    '[ "$(grep -nF "FW_OS_RELEASE=\"\$SQFS_ROOT/usr/lib/os-release\"" "$INST" | cut -d: -f1)" -lt "$(grep -nF "cp \"\$WORKDIR/version\" /usr/lib/version" "$INST" | cut -d: -f1)" ]' ""

###############################################################################
# unifi-core-storage-patch.sh
###############################################################################
# Synthetic bundles holding just the tokens the script looks for.
B51='/* fixture */async function f(){let e=[];e=JSON.parse((await Q("ustorage",["space","inspect"])).stdout);iwe={space:e,disks:[],sdcards:[]};}'
B60='/* fixture */async function f(){await q("ustorage",["worm","check"]);fe.updateState({disks:[]});}'
BDRIFT='/* fixture */async function f(){let e=[];e=JSON.parse((await Q("ustorage",["space","inspect"])).stdout);xyz={space:e,disks:[],sdcards:[]};}'
runpatch() { SVC="$1" PUSH_CONF="$T/no-push.conf" bash "$PATCH" 2>&1; }

printf '%s\n' "$B51" > "$T/svc51.js"; reset_calls
out=$(runpatch "$T/svc51.js"); rc=$?
check "patch: 5.1 bundle gets Patch A" \
    '[ $rc = 0 ] && grep -q "Patch A applied" <<<"$out" && [ "$(grep -cF "[\"disk\",\"inspect\"]" "$T/svc51.js")" = 1 ] && cmp -s <(printf "%s\n" "$B51") "$T/svc51.js.prepatch"' "$out"
out=$(runpatch "$T/svc51.js")
check "patch: second run is a no-op" 'grep -q "already applied" <<<"$out"' "$out"

printf '%s\n' "$B60" > "$T/svc60.js"; reset_calls
out=$(runpatch "$T/svc60.js"); rc=$?
check "patch: 6.0 bundle (no space-inspect call) -> not needed, no alert, untouched" \
    '[ $rc = 0 ] && grep -q "not needed" <<<"$out" && ! grep -q ALERT <<<"$out" && [ -z "$(calls)" ] && cmp -s <(printf "%s\n" "$B60") "$T/svc60.js" && [ ! -e "$T/svc60.js.prepatch" ]' "$out
$(calls)"

printf '%s\n' "$BDRIFT" > "$T/svcdrift.js"; reset_calls
out=$(runpatch "$T/svcdrift.js"); rc=$?
check "patch: 5.1-style bundle with a renamed anchor still alerts" \
    '[ $rc = 0 ] && grep -q "ALERT: Patch A anchor not found" <<<"$out" && grep -q "logger -t unifi-core-storage-patch -p daemon.err" <<<"$(calls)" && cmp -s <(printf "%s\n" "$BDRIFT") "$T/svcdrift.js"' "$out
$(calls)"

# A 5.1.x whose call gains arguments, or loses the call but keeps the
# snapshot shape, must not be mistaken for 6.0.
printf '%s\n' "${B51//\"inspect\"\]/\"inspect\",\"--json\"]}" > "$T/svcargs.js"
out=$(runpatch "$T/svcargs.js")
check "patch: call with extra arguments + anchor -> still patched" 'grep -q "Patch A applied" <<<"$out"' "$out"
printf '%s\n' "${BDRIFT//\"inspect\"\]/\"inspect\",\"--json\"]}" > "$T/svcargsdrift.js"
out=$(runpatch "$T/svcargsdrift.js")
check "patch: call with extra arguments + drifted anchor -> still alerts" 'grep -q "ALERT" <<<"$out"' "$out"
printf '%s\n' '/* fixture */abc={space:e,disks:[],sdcards:[]};' > "$T/svcshape.js"
out=$(runpatch "$T/svcshape.js")
check "patch: snapshot shape without the call -> anchor check, alert" 'grep -q "ALERT" <<<"$out"' "$out"

###############################################################################
# ubntnas guard: the console UI's Update must not reach ubntnas
###############################################################################
# A fake real binary that records how it was called.
cat > "$T/ubntnas.real" <<EOF
#!/bin/sh
echo "real \$*" >> "$T/real.calls"
exit 7
EOF
chmod +x "$T/ubntnas.real"
guard() { : > "$T/real.calls"; reset_calls; UBNTNAS_REAL="$T/ubntnas.real" bash "$GUARD" "$@"; }
out=$(guard system upgrade /tmp/fwupdate.abc -f --no-reboot); rc=$?
check "ubntnas guard: ubnt-systool's 'system upgrade <file> -f --no-reboot' is refused" \
    '[ $rc = 1 ] && grep -q "disabled on this VM" <<<"$out" && grep -q "update-unifi.sh --sync-os" <<<"$out" && [ ! -s "$T/real.calls" ]' "$out"
check "ubntnas guard: the refusal is logged" \
    'grep -q "logger -t ubntnas-vm-guard -p daemon.warning refused: ubntnas system upgrade /tmp/fwupdate.abc -f --no-reboot" <<<"$(calls)"' "$(calls)"
out=$(guard -v system upgrade /tmp/f); rc=$?
check "ubntnas guard: a global flag in front does not get past" '[ $rc = 1 ] && [ ! -s "$T/real.calls" ]' "$out"
out=$(guard system reset --no-reboot --do-format); rc=$?
check "ubntnas guard: everything else (system reset ...) runs the real binary, args and rc intact" \
    '[ $rc = 7 ] && [ "$(cat "$T/real.calls")" = "real system reset --no-reboot --do-format" ]' "$out
$(cat "$T/real.calls")"
out=$(UBNTNAS_REAL="$T/missing" bash "$GUARD" system reset 2>&1); rc=$?
check "ubntnas guard: no real binary -> clear error, not a loop" '[ $rc = 1 ] && grep -q "no real ubntnas" <<<"$out"' "$out"
cp "$GUARD" "$T/guard-as-real"
to=(); command -v timeout >/dev/null 2>&1 && to=(timeout 10)   # none on macOS
out=$(UBNTNAS_REAL="$T/guard-as-real" "${to[@]}" bash "$GUARD" system reset 2>&1); rc=$?
check "ubntnas guard: refuses to exec itself as the real binary" '[ $rc = 1 ] && grep -q "no real ubntnas" <<<"$out"' "$out"
check "install-shims.sh diverts ubntnas to ubntnas.real and installs the guard" \
    'grep -q "dpkg-divert --local --rename --divert /usr/bin/ubntnas.real" "$SHIMS" && grep -qF "wrappers/rootfs/usr/bin/ubntnas" "$SHIMS" && grep -q "mv -f /usr/bin/ubntnas.new /usr/bin/ubntnas" "$SHIMS"' ""
check "--verify checks the ubntnas guard" 'grep -q "ubntnas firmware-update guard" "$UPD"' ""

###############################################################################
# ustorage: worm check (new in 6.0) and unknown verbs
###############################################################################
out=$(python3 -I -B "$UST" worm check)
check "ustorage worm check: the real 6.0 no-WORM summary" \
    '[ "$(jq -cS . <<<"$out")" = "{\"counts\":{\"compliance\":0,\"enterprise\":0},\"has_worm\":false,\"modes\":[]}" ]' "$out"
out=$(python3 -I -B "$UST" worm check --details)
check "ustorage worm check --details: the real 6.0 no-WORM details" \
    '[ "$(jq -cS . <<<"$out")" = "{\"counts\":{\"compliance\":0,\"enterprise\":0},\"devices\":{},\"worm_found\":false}" ]' "$out"
out=$(python3 -I -B "$UST" rwfs check)
check "ustorage rwfs check unchanged" \
    '[ "$(jq -cS . <<<"$out")" = "{\"isMigrated\":false,\"migratable\":{\"canMigrate\":false,\"reason\":\"not-support\"}}" ]' "$out"
out=$(python3 -I -B "$UST" space replay-late-mount; echo "rc=$?")
check "ustorage space replay-late-mount (6.0 boot hook): silent no-op" '[ "$out" = "rc=0" ]' "$out"

###############################################################################
# Opt-in: the real unpacked firmware
###############################################################################
if [ -n "${FW_ROOT_51:-}" ] && [ -f "$FW_ROOT_51/usr/share/unifi-core/app/service.js" ]; then
    cp "$FW_ROOT_51/usr/share/unifi-core/app/service.js" "$T/real51.js"
    out=$(runpatch "$T/real51.js")
    check "real 5.1.33 service.js: Patch A applies once" \
        'grep -q "Patch A applied" <<<"$out" && [ "$(grep -cF "[\"disk\",\"inspect\"]" "$T/real51.js")" = 1 ]' "$out"
    check "real 5.1.33 root passes the Debian guard on bullseye" \
        'upd fw_debian_matches "$FW_ROOT_51" bullseye' ""
fi
if [ -n "${FW_ROOT_60:-}" ] && [ -f "$FW_ROOT_60/usr/share/unifi-core/app/service.js" ]; then
    cp "$FW_ROOT_60/usr/share/unifi-core/app/service.js" "$T/real60.js"; reset_calls
    out=$(runpatch "$T/real60.js")
    check "real 6.0.11 service.js: not needed, no alert" \
        'grep -q "not needed" <<<"$out" && [ -z "$(calls)" ] && cmp -s "$FW_ROOT_60/usr/share/unifi-core/app/service.js" "$T/real60.js"' "$out"
    out=$(upd fw_debian_matches "$FW_ROOT_60" bullseye 2>&1); rc=$?
    check "real 6.0.11 root is refused on bullseye" '[ $rc != 0 ] && grep -q trixie <<<"$out"' "$out"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
