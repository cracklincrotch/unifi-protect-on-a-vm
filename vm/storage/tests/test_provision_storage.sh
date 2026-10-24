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
STORAGE_VOLUME="$T/volume1"

rec()   { echo "$*" >> "$T/calls"; }
calls() { cat "$T/calls" 2>/dev/null; }
reset() { : > "$T/calls"; }
mdadm()     { rec mdadm "$@"; }
mkswap()    { rec mkswap "$@"; }
mkfs.ext4() { rec mkfs.ext4 "$@"; }
sgdisk()    { rec sgdisk "$@"; }
wipefs()    { rec wipefs "$@"; }
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
blkid() {
    rec blkid "$@"
    case "$1" in
        -U) case " $PRESENT " in *" $2 "*) echo /dev/vda3; return 0 ;; esac ;;
        -o) if [ "$4" = UUID ] && [ "$5" = "$SWAP_DEV" ] && [ -n "$SWAP_DEV_UUID" ]; then
                echo "$SWAP_DEV_UUID"; return 0
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
fstab "UUID=$(echo "$MD0_SWAP" | tr a-f A-F) none swap sw 0 0"
out=$(fstab_swap_uuid 2>&1)
check "an upper-case UUID (systemd would not match it either) is ignored" '[ -z "$out" ]' "$out"
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

check "no real tool was reached" '[ ! -s "$T/guard.log" ]' "$(cat "$T/guard.log" 2>/dev/null)"
echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
