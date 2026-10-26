#!/bin/bash
# Stubbed tests for vm/storage/rootfs/usr/local/sbin/provision-storage.sh.
# Runs on any Linux with bash 4+, as any user, with no disks and no VM: the
# script is SOURCED, which defines its functions and runs nothing, and every
# command that could touch a disk or the running system is replaced by a shell
# function that records its arguments in $T/calls. A guard directory first on
# PATH holds a failing stand-in for each real tool, so anything the stubs miss
# fails the run instead of reaching the machine.
# usage: vm/storage/tests/test_provision_storage.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
PS="$HERE/../rootfs/usr/local/sbin/provision-storage.sh"
T=$(mktemp -d /tmp/provtest.XXXX)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; echo "$2" | head -12 | sed 's/^/      /'; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$3"; fi; }

mkdir -p "$T/guard"
for c in sgdisk mdadm mkfs.ext4 mkswap blkid wipefs partprobe udevadm swapon \
         swapoff mount umount mountpoint fuser systemctl; do
    printf '#!/bin/sh\necho "GUARD: real %s $*" >> "%s/guard.log"\nexit 99\n' "$c" "$T" > "$T/guard/$c"
    chmod +x "$T/guard/$c"
done
PATH="$T/guard:$PATH"

# Source the script as root would run it, minus the side effects.
id() { [ "${1:-}" = -u ] && echo 0 || command id "$@"; }
export PROVISION_STORAGE_CONFIG="$T/unifi-storage"
# shellcheck source=/dev/null
. "$PS" >/dev/null || { echo "FAIL  could not source $PS"; exit 1; }
set +u
FSTAB="$T/fstab"
MDSTAT="$T/mdstat"      # absent until a test writes it: never the real one
LOCK="$T/lock"
RECOVER_LOCK="$T/recover.lock"
STORAGE_VOLUME="$T/volume1"
# Keep the real ones that the stubs below replace, to test them directly.
eval "real_$(declare -f scan_arrays)"
eval "real_$(declare -f stop_volume_users)"

rec()   { echo "$*" >> "$T/calls"; }
calls() { cat "$T/calls" 2>/dev/null; }
reset() { : > "$T/calls"; }
# mdadm --run <md>: starts only the arrays listed in RUN_OK.
# mdadm --detail|--examine --export <dev>: MD_NAME from NAMES ("dev=name ...").
RUN_OK=""; NAMES=""
mdadm() {
    rec mdadm "$@"
    case "$1" in
        --run) case " $RUN_OK " in *" $2 "*) return 0 ;; esac; return 1 ;;
        --detail|--examine)
            local n
            for n in $NAMES; do [ "${n%%=*}" = "$3" ] && echo "MD_NAME=${n#*=}"; done ;;
    esac
    return 0
}
mkswap()    { rec mkswap "$@"; }
mkfs.ext4() { rec mkfs.ext4 "$@"; }
sgdisk()    { rec sgdisk "$@"; }
# wipefs also notes whether vm-resume-recover.sh's lock is held meanwhile.
wipefs() {
    rec wipefs "$@"
    if command -v flock >/dev/null 2>&1 && ! flock -n "$RECOVER_LOCK" true 2>/dev/null; then
        rec "wipefs: recover lock held"
    fi
    return 0
}
swapoff()   { rec swapoff "$@"; }
partprobe() { :; }
udevadm()   { :; }
sleep()     { :; }
hostname()  { echo testhost; }
mountpoint() { return 1; }
# mount_arrays mounts, swaps on and relinks /srv: never run it here.
mount_arrays() { rec mount_arrays "$DATA_MD" "$SWAP_MD"; }
# blkid -U <uuid>: found when <uuid> is in $PRESENT.
# blkid -o value -s UUID <dev>: $SWAP_DEV_UUID for $SWAP_DEV.
# blkid -o value -s TYPE <dev>: from TYPES ("dev=type ...").
TYPES=""
blkid() {
    rec blkid "$@"
    case "$1" in
        -U) case " $PRESENT " in *" $2 "*) echo /dev/vda3; return 0 ;; esac ;;
        -o) if [ "$4" = UUID ] && [ "$5" = "$SWAP_DEV" ] && [ -n "$SWAP_DEV_UUID" ]; then
                echo "$SWAP_DEV_UUID"; return 0
            fi
            if [ "$4" = TYPE ]; then
                local t
                for t in $TYPES; do [ "${t%%=*}" = "$5" ] && { echo "${t#*=}"; return 0; }; done
            fi ;;
    esac
    return 2
}

ROOT_UUID=0f0f0f0f-0000-1111-2222-333333333333
NVME_SWAP=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee   # swap on the OS disk, present
MD0_SWAP=1a1a1a1a-2b2b-3c3c-4d4d-5e5e5e5e5e5e    # the DAS swap array's
OTHER=99999999-8888-7777-6666-555555555555
PRESENT="$ROOT_UUID $NVME_SWAP"
SWAP_DEV=""; SWAP_DEV_UUID=""
fstab() {  # fstab [extra lines]: a typical guest fstab plus the extras
    cat > "$FSTAB" <<EOF
# /etc/fstab: static file system information.
UUID=$ROOT_UUID /     ext4 errors=remount-ro 0 1
UUID=$NVME_SWAP none  swap sw,pri=100         0 0
/dev/vdb        /ssd1 ext4 defaults           0 2
EOF
    [ $# -eq 0 ] || printf '%s\n' "$@" >> "$FSTAB"
}
md0_line="UUID=$MD0_SWAP none swap sw,pri=1,nofail 0 0"

###############################################################################
# 1. fstab_swap_uuid: which UUID the new md0 swap gets
###############################################################################

fstab "$md0_line"
out=$(fstab_swap_uuid 2>&1)
check "no array to replace: the one fstab swap UUID no device carries is md0's" '[ "$out" = "$MD0_SWAP" ]' "$out"
out=$(fstab_swap_uuid "$MD0_SWAP" 2>&1)
check "replacing an array whose UUID fstab names: keep it" '[ "$out" = "$MD0_SWAP" ]' "$out"
out=$(fstab_swap_uuid "$OTHER" 2>&1)
check "replacing an array fstab does not name: the orphan pri=1 line (an fstab an older Erase left behind)" '[ "$out" = "$MD0_SWAP" ]' "$out"
out=$(fstab_swap_uuid "" 2>&1)
check "replacing an array with no readable UUID: the orphan pri=1 line" '[ "$out" = "$MD0_SWAP" ]' "$out"
fstab "UUID=$OTHER none swap sw 0 0"; PRESENT="$PRESENT $OTHER"
out=$(fstab_swap_uuid 2>&1); PRESENT="$ROOT_UUID $NVME_SWAP"
check "no orphan when every swap line's device is present (NVMe swap included)" '[ -z "$out" ]' "$out"

fstab
out=$(fstab_swap_uuid 2>&1)
check "fstab without an md0 swap line: nothing" '[ -z "$out" ]' "$out"
rm -f "$FSTAB"
out=$(fstab_swap_uuid 2>&1); rc=$?
check "missing fstab: nothing, quietly" '[ $rc = 0 ] && [ -z "$out" ]' "$out"
out=$(fstab_swap_uuid "$MD0_SWAP" 2>&1)
check "missing fstab, replacing an array: nothing" '[ -z "$out" ]' "$out"
mkdir "$FSTAB"
out=$(fstab_swap_uuid 2>&1); rc=$?
check "unreadable fstab (a directory): nothing" '[ $rc = 0 ] && [ -z "$out" ]' "$out"
rmdir "$FSTAB"

fstab "#$md0_line"
out=$(fstab_swap_uuid 2>&1)
check "a commented-out md0 line does not count" '[ -z "$out" ]' "$out"
fstab "   $md0_line"
out=$(fstab_swap_uuid 2>&1)
check "leading whitespace is fine" '[ "$out" = "$MD0_SWAP" ]' "$out"
fstab "UUID=\"$MD0_SWAP\" none swap sw,pri=1 0 0"
out=$(fstab_swap_uuid 2>&1)
check "a quoted UUID=\"...\" counts" '[ "$out" = "$MD0_SWAP" ]' "$out"
fstab "UUID=$(echo "$MD0_SWAP" | tr a-f A-F) none swap sw,pri=1 0 0"
out=$(fstab_swap_uuid 2>/dev/null); err=$(fstab_swap_uuid 2>&1 >/dev/null)
check "an upper-case UUID (systemd would not match it either) is ignored, with a warning" '[ -z "$out" ] && grep -q "upper case" <<<"$err"' "$out / $err"
fstab "UUID=$MD0_SWAP /data ext4 defaults 0 2"
out=$(fstab_swap_uuid 2>&1)
check "a non-swap line with an orphan UUID is ignored" '[ -z "$out" ]' "$out"
fstab "UUID=\$(touch $T/pwned) none swap sw 0 0" "UUID=not-a-uuid none swap sw 0 0" \
      "UUID=$MD0_SWAP-0 none swap sw 0 0" "UUID=$MD0_SWAP" "UUID=$MD0_SWAP none" \
      "$(printf 'UUID=\001\002\377 none swap')" "garbage"
out=$(fstab_swap_uuid 2>&1); rc=$?
check "malformed lines are ignored, and nothing in fstab is executed" '[ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$T/pwned" ]' "$out"
fstab "$md0_line" "$md0_line"
out=$(fstab_swap_uuid 2>&1)
check "the same md0 line twice is still one UUID" '[ "$out" = "$MD0_SWAP" ]' "$out"
fstab "$md0_line" "UUID=$OTHER none swap defaults,pri=1 0 0"
out=$(fstab_swap_uuid 2>/dev/null); err=$(fstab_swap_uuid 2>&1 >/dev/null)
check "two orphan pri=1 swap lines: no guess, and a warning" '[ -z "$out" ] && grep -q "cannot tell which" <<<"$err"' "$out / $err"
fstab "$md0_line" "UUID=$OTHER none swap sw 0 0"
out=$(fstab_swap_uuid 2>/dev/null)
check "an orphan without pri=1 next to md0's line does not get in the way" '[ "$out" = "$MD0_SWAP" ]' "$out"
for opts in "sw" "sw,pri=100" "pri=10" "sw,pri=1x" "nopri=1"; do
    fstab "UUID=$MD0_SWAP none swap $opts 0 0"
    out=$(fstab_swap_uuid "$OTHER" 2>/dev/null); err=$(fstab_swap_uuid 2>&1 >/dev/null)
    check "an orphan line with options '$opts' is not adopted (md0's priority must not change), and says so" '[ -z "$out" ] && grep -q "without pri=1" <<<"$err"' "$out / $err"
done
for opts in "pri=1" "defaults,pri=1" "pri=1,nofail"; do
    fstab "UUID=$MD0_SWAP none swap $opts 0 0"
    out=$(fstab_swap_uuid 2>/dev/null)
    check "an orphan line with options '$opts' is md0's" '[ "$out" = "$MD0_SWAP" ]' "$out"
done
fstab "$md0_line"; sum=$(cksum < "$FSTAB")
fstab_swap_uuid >/dev/null 2>&1; fstab_swap_uuid "$MD0_SWAP" >/dev/null 2>&1
check "fstab is never written" '[ "$(cksum < "$FSTAB")" = "$sum" ]' ""

###############################################################################
# 2. mkswap gets -U on every path that provisions
###############################################################################

data_disks() { echo sdx; echo sdy; }   # names /sys/block will not have
is_blank()   { return 0; }
stop_volume_users() { :; }

reset; out=$( (provision "sdx sdy" "$MD0_SWAP") 2>&1 ); rc=$?
check "provision with a UUID: mkswap -U <it> /dev/md0" '[ $rc = 0 ] && calls | grep -qx "mkswap -U $MD0_SWAP /dev/md0"' "$out
$(calls)"
reset; out=$( (provision "sdx sdy" "") 2>&1 ); rc=$?
check "provision without one: plain mkswap /dev/md0, and says fstab is left alone" '[ $rc = 0 ] && calls | grep -qx "mkswap /dev/md0" && grep -q "left alone" <<<"$out"' "$out
$(calls)"

# Erase: md0 exists, fstab names its swap UUID.
scan_arrays() { DATA_MD=/dev/md3; SWAP_MD=/dev/md0; }
SWAP_DEV=/dev/md0; SWAP_DEV_UUID=$MD0_SWAP; PRESENT="$PRESENT $MD0_SWAP"
fstab "$md0_line"
reset; out=$( (do_nuke) </dev/null 2>&1 ); rc=$?
first_wipe=$(calls | grep -n '^wipefs' | head -1 | cut -d: -f1)
read_uuid=$(calls | grep -n "^blkid -o value -s UUID /dev/md0" | head -1 | cut -d: -f1)
check "Erase keeps md0's swap UUID: read before the wipe, given to mkswap -U" '[ $rc = 0 ] && calls | grep -qx "mkswap -U $MD0_SWAP /dev/md0" && [ -n "$read_uuid" ] && [ -n "$first_wipe" ] && [ "$read_uuid" -lt "$first_wipe" ]' "$out
$(calls)"
check "... and leaves fstab as it was" 'grep -qx "$md0_line" "$FSTAB" && [ "$(grep -c swap "$FSTAB")" = 2 ]' "$(cat "$FSTAB")"

# Erase: md0 carries a UUID fstab does not name, and fstab's md0 line names
# an older one (what an Erase before this fix left behind).
SWAP_DEV_UUID=$OTHER; PRESENT="$ROOT_UUID $NVME_SWAP $OTHER"
fstab "$md0_line"
reset; out=$( (do_nuke) </dev/null 2>&1 ); rc=$?
check "Erase repairs an fstab an older Erase left out of step: md0 gets fstab's UUID" '[ $rc = 0 ] && calls | grep -qx "mkswap -U $MD0_SWAP /dev/md0"' "$out
$(calls)"
fstab "UUID=$MD0_SWAP none swap sw,pri=100 0 0"
reset; out=$( (do_nuke) </dev/null 2>&1 ); rc=$?
check "... but not from a line without pri=1: plain mkswap" '[ $rc = 0 ] && calls | grep -qx "mkswap /dev/md0"' "$out
$(calls)"
fstab "$md0_line"

# Erase with no swap array present: fall back to the orphan line.
scan_arrays() { DATA_MD=""; SWAP_MD=""; }
PRESENT="$ROOT_UUID $NVME_SWAP"
reset; out=$( (do_nuke) </dev/null 2>&1 ); rc=$?
check "Erase with no swap array: the orphan md0 line's UUID" '[ $rc = 0 ] && calls | grep -qx "mkswap -U $MD0_SWAP /dev/md0"' "$out
$(calls)"

# Boot with AUTOMODE on blank disks, and the provision action's path.
AUTOMODE=true
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot auto-provision of blank disks: the orphan md0 line's UUID" '[ $rc = 0 ] && calls | grep -qx "mkswap -U $MD0_SWAP /dev/md0"' "$out
$(calls)"
AUTOMODE=false

###############################################################################
# 3. A data array assembled but not running at boot (a member missing)
###############################################################################

RETRY_SECS=20; RETRY_EVERY=5
sleep() { rec sleep "$@"; }
# systemctl is-active <unit>: from UNIT_STATES ("unit=state ...").
# systemctl --no-block start: fails when START_FAILS is set.
UNIT_STATES=""; START_FAILS=""
systemctl() {
    rec systemctl "$@"
    case "$1" in
        is-active)
            local s
            for s in $UNIT_STATES; do
                [ "${s%%=*}" = "$2" ] && { echo "${s#*=}"; return 0; }
            done
            echo inactive; return 3 ;;
        --no-block) [ "$2" = start ] && [ -n "$START_FAILS" ] && return 5 ;;
    esac
    return 0
}
DEGRADED=0
md_degraded() { echo "$DEGRADED"; }
# What provisioning or an Erase would write. (Boot mode's `mdadm --run` of
# an existing array is checked for separately.)
writes() { calls | grep -E '^(mdadm --create|mdadm --zero|mdadm --stop|sgdisk|wipefs|mkswap|mkfs\.ext4|swapoff)'; }

# A DAS disk missing at boot: md0 and md3 both short a member, left
# inactive by the initramfs.
cat > "$T/mdstat.inactive" <<'EOF'
Personalities : [raid1] [raid10]
md3 : inactive sdy5[1](S) sdx5[0](S)
      7804333056 blocks super 1.2

md0 : inactive sdy2[1](S) sdx2[0](S)
      2095104 blocks super 1.2

unused devices: <none>
EOF
cat > "$T/mdstat.ok" <<'EOF'
Personalities : [raid1] [raid10]
md3 : active raid10 sdd5[2] sdc5[1] sdb5[0]
      7804333056 blocks super 1.2 512K chunks 2 near-copies [3/3] [UUU]

md0 : active raid1 sdd2[2] sdc2[1] sdb2[0]
      2095104 blocks super 1.2 [3/3] [UUU]

unused devices: <none>
EOF
cat > "$T/mdstat.external" <<'EOF'
Personalities : [raid1]
md127 : inactive sdb[0](S)
      5288 blocks super external:imsm

unused devices: <none>
EOF
cp "$T/mdstat.inactive" "$MDSTAT"; out=$(inactive_arrays 2>&1 | tr '\n' ' ')
check "inactive_arrays: md3 and md0" '[ "$out" = "/dev/md3 /dev/md0 " ]' "$out"
cp "$T/mdstat.ok" "$MDSTAT"; out=$(inactive_arrays 2>&1)
check "inactive_arrays: nothing when all run" '[ -z "$out" ]' "$out"
cp "$T/mdstat.external" "$MDSTAT"; out=$(inactive_arrays 2>&1)
check "inactive_arrays: an external-metadata container (always inactive) is left out" '[ -z "$out" ]' "$out"
printf 'md3 : inactive sdy5[1](S)' > "$MDSTAT"; out=$(inactive_arrays 2>&1)
check "inactive_arrays: a last line without its blocks line still counts" '[ "$out" = /dev/md3 ]' "$out"
rm -f "$MDSTAT"; out=$(inactive_arrays 2>&1)
check "inactive_arrays: nothing, quietly, without /proc/mdstat" '[ -z "$out" ]' "$out"

# Which arrays boot mode may start: members on the stubbed data disks sdx and
# sdy, named as provision() names them.
parent_disk() { echo "${1%%[0-9]*}"; }
OWN_NAMES="/dev/sdy5=testhost:3 /dev/sdy2=testhost:0"; NAMES=$OWN_NAMES
cp "$T/mdstat.inactive" "$MDSTAT"; out=$(md_members /dev/md3)
check "md_members: md3's members as mdstat lists them" '[ "$out" = "sdy5 sdx5 " ]' "$out"
cp "$T/mdstat.ok" "$MDSTAT"; out=$(md_members /dev/md3)
check "md_members: a running array's too" '[ "$out" = "sdd5 sdc5 sdb5 " ]' "$out"
cp "$T/mdstat.inactive" "$MDSTAT"
check "own_array: md3 and md0 on data disks, named *:3 and *:0" 'own_array /dev/md3 && own_array /dev/md0' ""
NAMES="/dev/sdy5=UNVR:3"
check "own_array: an imported UNVR data array (named *:3) counts" 'own_array /dev/md3' ""
NAMES="/dev/sdy5=otherbox:126"
check "own_array: another name does not" '! own_array /dev/md3' ""
NAMES=""
check "own_array: no name does not" '! own_array /dev/md3' ""
printf 'md3 : inactive vdb5[1](S) sdx5[0](S)\n' > "$MDSTAT"; NAMES="/dev/vdb5=testhost:3"
check "own_array: a member on a disk that is not a data disk (vdb, /ssd1) does not" '! own_array /dev/md3' ""
printf 'md3 : inactive sdy[1](S) sdx[0](S)\n' > "$MDSTAT"; NAMES="/dev/sdy=testhost:3"
check "own_array: whole-disk members do not" '! own_array /dev/md3' ""
check "own_array: an array mdstat does not list does not" '! own_array /dev/md9' ""
cp "$T/mdstat.inactive" "$MDSTAT"; NAMES="/dev/sdx5=testhost:3"   # sdy5, listed first, does not answer
check "own_array: the name comes from the first member that answers" 'own_array /dev/md3' ""
NAMES=$OWN_NAMES; rm -f "$MDSTAT"

# The real scan_arrays: which ext4 array becomes /volume1.
md_devices() { printf '%s\n' /dev/md0 /dev/md126 /dev/md127 /dev/md3; }
TYPES="/dev/md0=swap /dev/md126=ext4 /dev/md127=ext4 /dev/md3=ext4"
real_scan_arrays
check "scan_arrays: /dev/md3 wins over md126 and md127, which sort before it" '[ "$DATA_MD" = /dev/md3 ] && [ "$SWAP_MD" = /dev/md0 ]' "$DATA_MD $SWAP_MD"
TYPES="/dev/md0=swap /dev/md126=ext4 /dev/md127=ext4"; NAMES="/dev/md126=otherbox:1 /dev/md127=UNVR:3"
real_scan_arrays
check "scan_arrays: without md3, the ext4 array named *:3" '[ "$DATA_MD" = /dev/md127 ]' "$DATA_MD"
NAMES=""
real_scan_arrays
check "scan_arrays: otherwise the first ext4 array, as before" '[ "$DATA_MD" = /dev/md126 ]' "$DATA_MD"
TYPES="/dev/md0=swap"
real_scan_arrays
check "scan_arrays: no ext4 array, no DATA_MD" '[ -z "$DATA_MD" ] && [ "$SWAP_MD" = /dev/md0 ]' "$DATA_MD $SWAP_MD"
NAMES=$OWN_NAMES; TYPES=""

# warn: the journal prefix only when stdout is the stream JOURNAL_STREAM names.
# Needs /proc and GNU stat, as the guest has.
: > "$T/journal"
if js=$(stat -L -c %d:%i "$T/journal" 2>/dev/null) && [ -e "/proc/$$/fd/1" ]; then
    warn_in() {  # warn_in <JOURNAL_STREAM>: source in a fresh bash, warn, to $T/journal
        JOURNAL_STREAM="$1" bash -c 'id() { echo 0; }; . "$1"; warn hello' _ "$PS" > "$T/journal" 2>/dev/null
    }
    warn_in "$js"; out=$(grep hello "$T/journal")
    warn_in "1:2"; out2=$(grep hello "$T/journal")
    check "warn: priority err when stdout is the journal, plain WARNING when JOURNAL_STREAM is someone else's" '[ "$out" = "<3>[provision-storage] hello" ] && [ "$out2" = "[provision-storage] WARNING: hello" ]' "$out / $out2"
else
    echo "SKIP  warn journal check (needs /proc and GNU stat)"
fi
out=$(warn hello)
check "warn: plain WARNING without JOURNAL_STREAM" '[ "$out" = "[provision-storage] WARNING: hello" ]' "$out"

# Boot: a DAS disk missing, md0 and md3 inactive; blank disks present and
# AUTOMODE on. scan_arrays finds an array once `mdadm --run` started it.
scan_arrays() {
    rec scan; DATA_MD=""; SWAP_MD=""
    calls | grep -qx "mdadm --run /dev/md3" && [ -z "${RUN_OK##*/dev/md3*}" ] && DATA_MD=/dev/md3
    calls | grep -qx "mdadm --run /dev/md0" && [ -z "${RUN_OK##*/dev/md0*}" ] && SWAP_MD=/dev/md0
    [ -n "$LATE_START" ] && DATA_MD=/dev/md3
    return 0
}
LATE_START=""
cp "$T/mdstat.inactive" "$MDSTAT"; AUTOMODE=true; RUN_OK="/dev/md0 /dev/md3"; DEGRADED=1
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot: arrays assembled but not running are started (mdadm --run), loudly" '[ $rc = 0 ] && calls | grep -qx "mdadm --run /dev/md3" && calls | grep -qx "mdadm --run /dev/md0" && grep -q "WARNING: /dev/md3 was assembled but not running (a member is missing): started it DEGRADED" <<<"$out"' "$out
$(calls)"
check "... then mounted in boot mode, reported degraded, no retry unit" 'calls | grep -qx "mount_arrays /dev/md3 /dev/md0" && grep -q "WARNING: data array /dev/md3 is DEGRADED" <<<"$out" && ! calls | grep -q provision-storage-retry' "$out
$(calls)"
check "... and nothing is provisioned or wiped, AUTOMODE and blank disks notwithstanding" '[ -z "$(writes)" ]' "$(calls)"
check "... the inactive list is read before the scan" '[ "$(calls | grep -n "^mdadm --run" | head -1 | cut -d: -f1)" -lt "$(calls | grep -n "^scan" | head -1 | cut -d: -f1)" ]' "$(calls)"

RUN_OK="/dev/md0"   # md3 has too few members to start
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot: an array that cannot start goes to the retry unit, loudly" '[ $rc = 0 ] && grep -q "WARNING: /dev/md3 is assembled but cannot start: too few members" <<<"$out" && grep -q "WARNING: no data array is running" <<<"$out" && calls | grep -qx "systemctl --no-block start provision-storage-retry.service"' "$out
$(calls)"
check "... with nothing provisioned, wiped or mounted" '[ -z "$(writes)" ] && ! calls | grep -q "^mount_arrays"' "$(calls)"
START_FAILS=1
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot: retry unit cannot start: still exit 0, and says how to retry by hand" '[ $rc = 0 ] && grep -q "once the array runs: .* retry" <<<"$out" && [ -z "$(writes)" ]' "$out"
START_FAILS=""
RUN_OK=""; LATE_START=1
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot: md3 starts on its own between the mdstat read and the scan: mounted, no retry" '[ $rc = 0 ] && calls | grep -q "^mount_arrays /dev/md3" && ! calls | grep -q provision-storage-retry' "$out
$(calls)"
LATE_START=""; AUTOMODE=false; DEGRADED=0

cp "$T/mdstat.external" "$MDSTAT"; is_blank() { return 1; }
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot: an external-metadata container is not started, and no retry unit" '[ $rc = 0 ] && ! calls | grep -q "mdadm --run" && ! calls | grep -q provision-storage-retry' "$out
$(calls)"
printf 'md127 : inactive sdy1[1](S) sdx1[0](S)\n      2095104 blocks super 1.2\n' > "$MDSTAT"
NAMES="/dev/sdy1=otherbox:127"; RUN_OK="/dev/md127"
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot: a foreign inactive array is not started, loudly, and no retry unit" '[ $rc = 0 ] && ! calls | grep -q "mdadm --run" && ! calls | grep -q provision-storage-retry && grep -q "not this VM.s own array" <<<"$out"' "$out
$(calls)"
AUTOMODE=true; is_blank() { return 0; }
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot: nothing is provisioned past a foreign inactive array, AUTOMODE and blank disks notwithstanding" '[ $rc = 0 ] && [ -z "$(writes)" ] && ! calls | grep -q "mdadm --run" && ! calls | grep -q provision-storage-retry && grep -q "none of them is this VM.s own" <<<"$out"' "$out
$(calls)"
AUTOMODE=false; is_blank() { return 1; }
cp "$T/mdstat.inactive" "$MDSTAT"; NAMES="/dev/sdx5=testhost:3 /dev/sdy2=testhost:0"; RUN_OK="/dev/md0 /dev/md3"
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot: md3 is still ours, started and mounted, when its first listed member does not answer --examine" '[ $rc = 0 ] && calls | grep -qx "mdadm --run /dev/md3" && calls | grep -q "^mount_arrays /dev/md3"' "$out
$(calls)"
NAMES=$OWN_NAMES; RUN_OK=""

# Boot: nothing inactive, disks with data: the old path, no retry.
rm -f "$MDSTAT"
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot: disks with data but no array: left alone as before, no retry unit" '[ $rc = 0 ] && grep -q "NOT touched" <<<"$out" && ! calls | grep -q "provision-storage-retry" && ! calls | grep -q "mdadm --run" && [ -z "$(writes)" ]' "$out
$(calls)"
is_blank() { return 0; }

# Boot: the data array runs, degraded or not.
scan_arrays() { rec scan; DATA_MD=/dev/md3; SWAP_MD=/dev/md0; }
DEGRADED=1
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot: a running but degraded array is mounted and reported loudly" '[ $rc = 0 ] && calls | grep -qx "mount_arrays /dev/md3 /dev/md0" && grep -q "WARNING: data array /dev/md3 is DEGRADED: running with 1 member(s) missing" <<<"$out" && ! calls | grep -q "provision-storage-retry"' "$out
$(calls)"
DEGRADED=0
reset; out=$( (do_boot) 2>&1 ); rc=$?
check "boot: a healthy array is mounted without a warning" '[ $rc = 0 ] && calls | grep -qx "mount_arrays /dev/md3 /dev/md0" && ! grep -q WARNING <<<"$out"' "$out"

# vm-resume-recover.sh stand-in: records its arguments, and whether the lock
# is free while it runs; exits RECOVER_RC.
RECOVER="$T/recover"; export RECOVER_RC=0
cat > "$RECOVER" <<EOF
#!/bin/bash
echo "recover \$*" >> "$T/calls"
if command -v flock >/dev/null 2>&1 && flock -n "$LOCK" true; then echo "recover: lock free" >> "$T/calls"; fi
exit \${RECOVER_RC:-0}
EOF
chmod +x "$RECOVER"

# Retry: the array starts on the third look.
scan_arrays() { rec scan; SWAP_MD=""; DATA_MD=""; [ "$(calls | grep -c ^scan)" -ge "$UP_AFTER" ] && DATA_MD=/dev/md3; }
UP_AFTER=3; DEGRADED=1
UNIT_STATES="ms.service=active msr.service=active mst.service=activating msp.service=failed"
cp "$T/mdstat.inactive" "$MDSTAT"
reset; out=$( (do_retry) 2>&1 ); rc=$?
mount_at=$(calls | grep -n '^mount_arrays' | cut -d: -f1)
recover_at=$(calls | grep -n '^recover ' | cut -d: -f1)
check "retry: mounts the array once it runs (3rd look, 2 sleeps)" '[ $rc = 0 ] && [ "$(calls | grep -c ^scan)" = 3 ] && [ "$(calls | grep -c "^sleep 5")" = 2 ] && calls | grep -qx "mount_arrays /dev/md3 "' "$out
$(calls)"
check "... then runs vm-resume-recover.sh once, with the reason, not a parallel restart" '[ -n "$recover_at" ] && [ "$mount_at" -lt "$recover_at" ] && [ "$(calls | grep -c "^recover ")" = 1 ] && calls | grep -qx "recover array mounted late by provision-storage-retry.service" && ! calls | grep -q "no-block restart"' "$(calls)"
check "... after clearing failed media units, and without holding the lock (it takes minutes)" 'calls | grep -qx "systemctl reset-failed ms.service msp.service msr.service mst.service" && { ! command -v flock >/dev/null || calls | grep -qx "recover: lock free"; }' "$(calls)"
check "... says loudly that the mount is late and the array degraded" 'grep -q "WARNING: data array /dev/md3 is running now; mounting it late" <<<"$out" && grep -q "WARNING: data array /dev/md3 is DEGRADED" <<<"$out"' "$out"
check "... and never assembles, starts or writes to an array" '[ -z "$(writes)" ] && ! calls | grep -q "^mdadm"' "$(calls)"
DEGRADED=0

RECOVER_RC=1; UP_AFTER=1
reset; out=$( (do_retry) 2>&1 ); rc=$?
check "retry: recording does not resume after the restart: exit 1, loudly" '[ $rc = 1 ] && calls | grep -q "^recover " && grep -q "WARNING: recording did NOT resume" <<<"$out"' "$out
$(calls)"
RECOVER_RC=0; RECOVER="$T/no-such-recover"
reset; out=$( (do_retry) 2>&1 ); rc=$?
check "retry: vm-resume-recover.sh missing: exit 1, loudly" '[ $rc = 1 ] && grep -q "WARNING: .*no-such-recover not found" <<<"$out"' "$out"
RECOVER="$T/recover"

UNIT_STATES="msr.service=inactive"
reset; out=$( (do_retry) 2>&1 ); rc=$?
check "retry: no media service started yet: mounts, restarts nothing" '[ $rc = 0 ] && calls | grep -q "^mount_arrays" && ! calls | grep -q "^recover" && grep -q "nothing to restart" <<<"$out"' "$out
$(calls)"

UP_AFTER=999
reset; out=$( (do_retry) 2>&1 ); rc=$?
check "retry: the array never runs: gives up after RETRY_SECS (5 looks, 4 sleeps), exit 1, loudly" '[ $rc = 1 ] && [ "$(calls | grep -c ^scan)" = 5 ] && [ "$(calls | grep -c ^sleep)" = 4 ] && grep -q "WARNING: gave up after 20s" <<<"$out" && grep -q "assembled but not running: /dev/md3" <<<"$out"' "$out
$(calls)"
check "... mounting and restarting nothing" '! calls | grep -q "^mount_arrays" && ! calls | grep -q "^recover" && [ -z "$(writes)" ]' "$(calls)"

mountpoint() { return 0; }
reset; out=$( (do_retry) 2>&1 ); rc=$?
check "retry: already mounted (by someone else): exit 0, touch nothing" '[ $rc = 0 ] && ! calls | grep -q "^scan" && ! calls | grep -q "^mount_arrays" && ! calls | grep -q "^recover"' "$out
$(calls)"
mountpoint() { return 1; }

# The lock: a retry attempt waits for a run in progress, and so does an
# Erase. Real flock, real sleep.
if command -v flock >/dev/null 2>&1; then
    hold() {  # hold [seconds]: hold the lock from another process
        flock "$LOCK" bash -c 'touch "$1.held"; exec sleep "$2"' _ "$LOCK" "${1:-2}" & HOLDER=$!
        while [ ! -e "$LOCK.held" ]; do command sleep 0.1; done; rm -f "$LOCK.held"
    }
    UP_AFTER=1; UNIT_STATES=""
    hold; t0=$(date +%s%N)
    reset; out=$( (do_retry) 2>&1 ); rc=$?
    dt=$(( ($(date +%s%N) - t0) / 1000000 )); wait "$HOLDER"
    check "retry waits for a run that holds the lock before it scans or mounts" '[ $rc = 0 ] && [ "$dt" -ge 1000 ] && calls | grep -q "^mount_arrays"' "$out (waited ${dt} ms)"
    scan_arrays() { rec scan; DATA_MD=/dev/md3; SWAP_MD=/dev/md0; }
    SWAP_DEV=/dev/md0; SWAP_DEV_UUID=$MD0_SWAP; fstab "$md0_line"
    hold; t0=$(date +%s%N)
    reset; out=$( (main nuke) </dev/null 2>&1 ); rc=$?
    dt=$(( ($(date +%s%N) - t0) / 1000000 )); wait "$HOLDER"
    check "an Erase (main nuke) waits for the lock too" '[ $rc = 0 ] && [ "$dt" -ge 1000 ] && calls | grep -q "^wipefs"' "$out (waited ${dt} ms)"
    hold; t0=$(date +%s%N)
    reset; out=$( (main boot) 2>&1 ); rc=$?
    dt=$(( ($(date +%s%N) - t0) / 1000000 )); wait "$HOLDER"
    check "... and so does boot mode" '[ $rc = 0 ] && [ "$dt" -ge 1000 ] && calls | grep -q "^mount_arrays"' "$out (waited ${dt} ms)"
    BOOT_LOCK_WAIT=1
    hold 4; t0=$(date +%s%N)
    reset; out=$( (main boot) 2>&1 ); rc=$?
    dt=$(( ($(date +%s%N) - t0) / 1000000 )); wait "$HOLDER"
    check "boot mode waits at most BOOT_LOCK_WAIT, then carries on, loudly" '[ $rc = 0 ] && [ "$dt" -ge 900 ] && [ "$dt" -lt 3500 ] && grep -q "WARNING: cannot take .* within 1s" <<<"$out" && calls | grep -q "^mount_arrays"' "$out (waited ${dt} ms)"
    BOOT_LOCK_WAIT=30
else
    echo "SKIP  lock checks (no flock)"
fi

###############################################################################
# 4. An Erase while /volume1 is not mounted
###############################################################################

fuser() { rec fuser "$@"; echo " 4242"; }
unit_of_pid() { echo msr.service; }
reset; out=$(real_stop_volume_users 2>&1)
check "stop_volume_users, /volume1 not mounted: no fuser, nothing stopped" '[ -z "${out// /}" ] && ! calls | grep -q "^fuser" && ! calls | grep -q "systemctl stop"' "$out
$(calls)"
mountpoint() { return 0; }
reset; out=$(real_stop_volume_users 2>&1)
check "stop_volume_users, mounted: stops what fuser finds, as before" 'calls | grep -q "^fuser -m $STORAGE_VOLUME" && calls | grep -q "^systemctl stop *msr.service" && grep -q msr.service <<<"$out"' "$out
$(calls)"
mountpoint() { return 1; }
stop_volume_users() { real_stop_volume_users "$@"; }
scan_arrays() { rec scan; DATA_MD=""; SWAP_MD=""; }
reset; out=$( (do_nuke) </dev/null 2>&1 ); rc=$?
check "Erase with /volume1 not mounted: no service stopped, the Erase completes" '[ $rc = 0 ] && ! calls | grep -q "^fuser" && ! calls | grep -q "systemctl stop" && calls | grep -q "^mkswap"' "$out
$(calls)"

# An Erase and vm-resume-recover.sh never overlap.
if command -v flock >/dev/null 2>&1; then
    flock "$RECOVER_LOCK" bash -c 'touch "$1.held"; exec sleep 2' _ "$RECOVER_LOCK" & H=$!
    while [ ! -e "$RECOVER_LOCK.held" ]; do command sleep 0.1; done; rm -f "$RECOVER_LOCK.held"
    reset; out=$( (main nuke) </dev/null 2>&1 ); rc=$?
    wait "$H"
    check "an Erase refuses while vm-resume-recover.sh runs, and touches nothing" '[ $rc != 0 ] && grep -q "vm-resume-recover.sh is running" <<<"$out" && ! calls | grep -q "^wipefs" && ! calls | grep -q "^mkswap"' "$out
$(calls)"
    reset; out=$( (main nuke) </dev/null 2>&1 ); rc=$?
    check "... and holds vm-resume-recover.sh's lock while it runs, so none starts meanwhile" '[ $rc = 0 ] && calls | grep -qx "wipefs: recover lock held"' "$out
$(calls)"
else
    echo "SKIP  Erase / recovery lock checks (no flock)"
fi

check "no real tool was reached" '[ ! -s "$T/guard.log" ]' "$(cat "$T/guard.log" 2>/dev/null)"
echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
