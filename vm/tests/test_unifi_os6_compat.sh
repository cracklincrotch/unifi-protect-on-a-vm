#!/bin/bash
# Tests for the UniFi OS 6.0 compatibility changes (docs/unifi-os-6-compat.md).
# Linux, no root, no VM, no network: every system command the code under test
# could reach is a stub on PATH, and the firmware is replaced by fixtures.
#
#   update-unifi.sh               version / track / platform helpers, the
#                                 firmware pick, the Debian guard, the
#                                 install-landed check, the ufcd mask
#   install-protect-baremetal.sh  fw_api_href, the ufcd mask, the platform
#   unifi-core-storage-patch.sh   5.1 patch, 6.0 no-op, anchor-drift alert
#   ustorage                      worm check, unknown verbs
#
# usage: vm/tests/test_unifi_os6_compat.sh
#        FW_ROOT_51=<5.1.33 squashfs-root> FW_ROOT_60=<6.0.11 squashfs-root> \
#            vm/tests/test_unifi_os6_compat.sh
#   The second form also runs the patch script and the Debian guard against
#   the real unpacked firmware (read-only: service.js is copied first).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
VM="$(cd "$HERE/.." && pwd)"
UPD="$VM/installers/update-unifi.sh"
INST="$VM/installers/install-protect-baremetal.sh"
PATCH="$VM/storage/rootfs/usr/local/bin/unifi-core-storage-patch.sh"
UST="$VM/storage/rootfs/usr/bin/ustorage"
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

# get_os_firmware with api_get / get_latest_version stubbed.
gof() {  # gof <track> <listing file> [FW_API_LIMIT]
    ( source "$UPD"
      [ -n "${3:-}" ] && FW_API_LIMIT=$3
      api_get() { echo "$1" >> "$T/urls"; cat "$LISTING"; }
      get_latest_version() { echo "get_latest_version $*" >> "$T/urls"; echo '{"version":"vLATEST"}'; }
      LISTING="$2" get_os_firmware "$1" )
}
: > "$T/urls"; out=$(gof 5.1 "$T/list-5.json" 2>&1)
u=$(cat "$T/urls")
check "get_os_firmware 5.1 queries the listing, filtered and with a limit" \
    'grep -q "/api/firmware?" <<<"$u" && grep -q "product~~unifi-nvr" <<<"$u" && grep -q "channel~~release" <<<"$u" && grep -q "platform~~UNVR" <<<"$u" && grep -q "version_major~~5&filter=eq~~version_minor~~1&limit=500" <<<"$u"' "$u"
check "get_os_firmware 5.1 returns 5.1.33" '[ "$(jq -r .version <<<"$out")" = v5.1.33+abc ]' "$out"
: > "$T/urls"; out=$(gof latest "$T/list-5.json" 2>&1)
check "get_os_firmware latest keeps the firmware-latest query" \
    'grep -q "get_latest_version unifi-nvr release UNVR" "$T/urls" && [ "$(jq -r .version <<<"$out")" = vLATEST ]' "$(cat "$T/urls")"
out=$(gof 6.x "$T/list-5.json" 2>&1); rc=$?
check "get_os_firmware rejects a bad track" '[ $rc != 0 ] && grep -q "is not .latest." <<<"$out"' "$out"
out=$(gof 5 "$T/list-5.json" 4 2>&1 >/dev/null)
check "get_os_firmware warns when the listing fills its limit" 'grep -q "hit its limit" <<<"$out"' "$out"

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

# dpkg-query stub: --admindir answers for the firmware, otherwise the system.
cat > "$T/bin/dpkg-query" <<EOF
#!/bin/sh
case "\$*" in
    *--admindir*) [ -n "\$FW_CORE" ] && printf '%s' "\$FW_CORE" && exit 0; exit 1 ;;
    *)            [ -n "\$SYS_CORE" ] && printf '%s' "\$SYS_CORE" && exit 0; exit 1 ;;
esac
EOF
chmod +x "$T/bin/dpkg-query"
out=$(FW_CORE=6.0.123 SYS_CORE=6.0.123 upd fw_install_landed "$T/fw60" 2>&1); rc=$?
check "fw_install_landed: unifi-core at the firmware's version" '[ $rc = 0 ]' "$out"
out=$(FW_CORE=6.0.123 SYS_CORE=5.1.132 upd fw_install_landed "$T/fw60" 2>&1); rc=$?
check "fw_install_landed: unifi-core left behind -> refuse to stamp" \
    '[ $rc != 0 ] && grep -q "unifi-core is .5.1.132., the firmware carries .6.0.123." <<<"$out"' "$out"
out=$(FW_CORE= SYS_CORE=5.1.132 upd fw_install_landed "$T/fw60" 2>&1); rc=$?
check "fw_install_landed: firmware without unifi-core -> refuse" '[ $rc != 0 ]' "$out"
rm -f "$T/bin/dpkg-query"

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
