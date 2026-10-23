#!/bin/bash
# Tests for the fixed host/snapshot.sh, run on mm.pc against throwaway qcow2
# images (offline path), plus STRICTLY READ-ONLY checks against the real VM:
# only `list`, and `delete` of a tag that cannot exist (refused before QMP).
# Never add create/restore/rollback/delete-of-a-real-tag against $REAL: if
# the tag is absent, create takes a LIVE snapshot of the production VM.
# usage: test_snapshot_sh.sh /path/to/snapshot.sh
#        REAL_CONF=/path/to/protect-on-mac.conf test_snapshot_sh.sh ...  adds the
#        read-only checks against the running VM (list, refuse a missing tag),
#        and the "refuse while the VM answers QMP" check against its socket.
SNAP="$1"
QI=/opt/homebrew/bin/qemu-img
QIO=/opt/homebrew/bin/qemu-io
T=$(mktemp -d /tmp/snaptest.XXXX)
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; echo "$2" | head -8 | sed 's/^/      /'; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$3"; fi; }

conf() {  # conf <file> <QMP_SOCKET> [extra lines]
    cat > "$1" <<EOF
VM_DATA_DIR="$T"
VM_DISK="$T/protect.qcow2"
SSD_IMAGE="$T/ssd1.qcow2"
STORAGE_IMAGES=()
QMP_SOCKET="$2"
$3
EOF
}
conf "$T/test.conf" "$T/no-such.sock"
for i in protect ssd1; do "$QI" create -q -f qcow2 "$T/$i.qcow2" 16M; done
fill() { for i in protect ssd1; do "$QIO" -f qcow2 -c "write -q -P $1 0 64k" "$T/$i.qcow2" >/dev/null; done; }
holds() { for i in ${2:-protect ssd1}; do "$QIO" -f qcow2 -c "read -q -P $1 0 64k" "$T/$i.qcow2" 2>&1 | grep -q "Pattern verification failed" && return 1; done; return 0; }
run() { PROTECT_ON_MAC_CONF="$T/test.conf" /bin/bash "$SNAP" "$@"; }
names() { "$QI" info -U --output=json "$T/$1.qcow2" | /opt/homebrew/bin/python3.14 -I -c 'import json,sys; [print(s["name"]) for s in json.load(sys.stdin).get("snapshots",[])]'; }
tags() { names "$1" | tr '\n' ' '; }
wipe() { local i t; for i in protect ssd1; do while [ -n "$(names $i)" ]; do t="$(names $i | head -1)"; "$QI" snapshot -d "$t" "$T/$i.qcow2" || break; done; done; [ -z "$(tags protect)$(tags ssd1)" ] || echo "WIPE FAILED"; }

fill 0x11
out=$(run list 2>&1); check "list on empty images says (no snapshots)" '[ "$(grep -c "(no snapshots)" <<<"$out")" = 2 ]' "$out"
out=$(run create A 2>&1); rc=$?
check "create A (offline) succeeds on both" '[ $rc = 0 ] && grep -q "created on all 2 images" <<<"$out" && [ "$(tags protect)" = "A " ] && [ "$(tags ssd1)" = "A " ]' "$out"
out=$(run create A 2>&1); rc=$?
check "create A again is idempotent" '[ $rc = 0 ] && grep -q "already exists" <<<"$out"' "$out"
out=$(run create 12 2>&1); rc=$?
check "create refuses an all-digit name" '[ $rc != 0 ] && grep -q "all digits" <<<"$out" && [ "$(tags protect)" = "A " ]' "$out"

fill 0x22
out=$(printf 'no\n' | run restore A 2>&1); rc=$?
check "restore aborts without YES and changes nothing" '[ $rc != 0 ] && holds 0x22' "$out"
out=$(printf 'YES\n' | run restore A 2>&1); rc=$?
check "restore A reverts BOTH images' data" '[ $rc = 0 ] && holds 0x11' "$out"

"$QI" snapshot -c B "$T/ssd1.qcow2"
fill 0x33
out=$(run create B 2>&1); rc=$?
check "create refuses a name already on 1 of 2 images" '[ $rc != 0 ] && grep -q "on 1 of 2 images" <<<"$out"' "$out"
out=$(printf 'YES\n' | run restore B 2>&1); rc=$?
check "restore refuses a half-present snapshot, data untouched" '[ $rc != 0 ] && grep -q "MISSING: *$T/protect.qcow2" <<<"$out" && holds 0x33' "$out"
out=$(run delete B 2>&1); rc=$?
check "delete of a half-present snapshot removes it and says where it was absent" '[ $rc = 0 ] && grep -q "not in this image" <<<"$out" && [ -z "$(tags ssd1 | grep -w B)" ]' "$out"
out=$(run delete A 2>&1); rc=$?
check "delete A removes it from both" '[ $rc = 0 ] && [ -z "$(tags protect)" ] && [ -z "$(tags ssd1)" ]' "$out"
out=$(run delete A 2>&1); rc=$?
check "delete of a missing snapshot is an error (was: 'deleted')" '[ $rc != 0 ] && grep -q "no snapshot named" <<<"$out"' "$out"

# All-digit tags made outside the script, and IDs that differ per image.
wipe
"$QI" snapshot -c X "$T/ssd1.qcow2"; "$QI" snapshot -d X "$T/ssd1.qcow2"   # ssd1 IDs now run one ahead
fill 0x41; for i in protect ssd1; do "$QI" snapshot -c A "$T/$i.qcow2"; done
fill 0x42; for i in protect ssd1; do "$QI" snapshot -c 1 "$T/$i.qcow2"; done
fill 0x43
out=$(printf 'YES\n' | run restore 1 2>&1); rc=$?
check "restore refuses an all-digit name typed by hand" '[ $rc != 0 ] && holds 0x43' "$out"
out=$(printf '1\nYES\n' | run rollback 2>&1); rc=$?
check "rollback to an all-digit tag reverts BOTH images to that tag (by ID), not to ID 1" '[ $rc = 0 ] && holds 0x42' "$out"
check "rollback list shows dates, not the size unit" 'grep -qE "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:" <<<"$out" && ! grep -qE " B [0-9]{4}-" <<<"$out"' "$out"
out=$(run delete 1 2>&1); rc=$?
check "an all-digit tag made elsewhere can still be deleted" '[ $rc = 0 ] && [ "$(tags protect)" = "A " ] && [ "$(tags ssd1)" = "A " ]' "$out"

# Rollback with a leading-zero choice and cleanup of newer snapshots.
wipe; fill 0x44; run create C1 >/dev/null 2>&1; fill 0x55; sleep 1; run create C2 >/dev/null 2>&1; fill 0x66
out=$(printf '02\ny\nYES\n' | run rollback 2>&1); rc=$?
check "rollback '02' picks row 2 and deletes the newer snapshot" '[ $rc = 0 ] && holds 0x44 && [ "$(tags protect)" = "C1 " ] && [ "$(tags ssd1)" = "C1 " ]' "$out"
"$QI" snapshot -c D "$T/protect.qcow2"; fill 0x77
out=$(printf '1\nYES\n' | run rollback 2>&1); rc=$?
check "rollback refuses a snapshot missing from /ssd1, data untouched" '[ $rc != 0 ] && grep -q "MISSING: *$T/ssd1.qcow2" <<<"$out" && holds 0x77' "$out"
"$QI" snapshot -d D "$T/protect.qcow2"

# Duplicate tag in one image (only possible from outside the script).
if "$QI" snapshot -c C1 "$T/ssd1.qcow2" 2>/dev/null; then
    out=$(printf 'YES\n' | run restore C1 2>&1); rc=$?
    check "restore refuses a tag held twice in one image" '[ $rc != 0 ] && grep -q "more than one" <<<"$out" && holds 0x77' "$out"
    out=$(run delete C1 2>&1); rc=$?
    check "delete removes every copy of a duplicated tag" '[ $rc = 0 ] && [ -z "$(tags protect)" ] && [ -z "$(tags ssd1)" ]' "$out"
else
    echo "SKIP  duplicate tags (qemu-img refuses them)"; run delete C1 >/dev/null 2>&1
fi

# Missing images and STORAGE_IMAGES "path|serial" entries.
"$QI" create -q -f qcow2 "$T/extra.qcow2" 16M
conf "$T/storage.conf" "$T/no-such.sock" "STORAGE_IMAGES=(\"$T/extra.qcow2|extra-001\")"
out=$(PROTECT_ON_MAC_CONF="$T/storage.conf" /bin/bash "$SNAP" create S 2>&1); rc=$?
check "STORAGE_IMAGES 'path|serial' entries are part of the set" '[ $rc = 0 ] && grep -q "created on all 3 images" <<<"$out" && [ "$("$QI" snapshot -l -U "$T/extra.qcow2" | awk "NR>2{print \$2}")" = S ]' "$out"
PROTECT_ON_MAC_CONF="$T/storage.conf" /bin/bash "$SNAP" delete S >/dev/null 2>&1
mv "$T/ssd1.qcow2" "$T/ssd1.away"
out=$(run create E 2>&1); rc=$?
check "a configured but missing SSD_IMAGE stops create" '[ $rc != 0 ] && grep -q "not found" <<<"$out" && [ -z "$(tags protect)" ]' "$out"
out=$(printf 'YES\n' | run restore C1 2>&1); rc=$?
check "a configured but missing SSD_IMAGE stops restore" '[ $rc != 0 ] && grep -q "not found" <<<"$out"' "$out"
out=$(run list 2>&1); rc=$?
check "list still works and flags the missing image" '[ $rc = 0 ] && grep -q "IMAGE FILE NOT FOUND" <<<"$out"' "$out"
mv "$T/ssd1.away" "$T/ssd1.qcow2"
"$QI" create -q -f qcow2 "$T/garbage.qcow2" 16M; printf '\000\000\000\143' | dd of="$T/garbage.qcow2" bs=1 seek=4 conv=notrunc 2>/dev/null   # qcow2 version 99: unreadable
conf "$T/badroot.conf" "$T/no-such.sock"; sed -i '' "s|^VM_DISK=.*|VM_DISK=\"$T/garbage.qcow2\"|" "$T/badroot.conf"
out=$(printf '1\n' | PROTECT_ON_MAC_CONF="$T/badroot.conf" /bin/bash "$SNAP" rollback 2>&1); rc=$?
check "rollback with an unreadable root image says so, not 'No snapshots found'" '[ $rc != 0 ] && grep -q "cannot read" <<<"$out" && ! grep -q "No snapshots found" <<<"$out"' "$out"

dd if=/dev/zero of="$T/raw.img" bs=64k count=4 2>/dev/null
conf "$T/rawroot.conf" "$T/no-such.sock"; sed -i '' "s|^VM_DISK=.*|VM_DISK=\"$T/raw.img\"|" "$T/rawroot.conf"
out=$(PROTECT_ON_MAC_CONF="$T/rawroot.conf" /bin/bash "$SNAP" create R 2>&1); rc=$?
check "a non-qcow2 root image is an error, not 'no snapshots'" '[ $rc != 0 ] && grep -q "cannot read" <<<"$out"' "$out"

# Round 2: numeric-looking names, names with spaces, shared names in rollback
# cleanup, a refused QMP socket with a live holder, the unfinished-restore marker.
wipe
fill 0x51; run create 7.1 >/dev/null 2>&1; fill 0x52; run create 7.10 >/dev/null 2>&1; fill 0x53
out=$(printf 'YES\n' | run restore 7.1 2>&1); rc=$?
check "restore 7.1 goes to 7.1, not refused as a duplicate of 7.10" '[ $rc = 0 ] && holds 0x51' "$out"
out=$(printf '1\nYES\n' | run rollback 2>&1); rc=$?
check "rollback to 7.10 goes to 7.10" '[ $rc = 0 ] && holds 0x52' "$out"
wipe
fill 0x61; for i in protect ssd1; do "$QI" snapshot -c pre "$T/$i.qcow2"; done
fill 0x62; for i in protect ssd1; do "$QI" snapshot -c "pre update" "$T/$i.qcow2"; done
fill 0x63
out=$(printf 'YES\n' | run restore pre 2>&1); rc=$?
check "a name with spaces made elsewhere does not shadow 'pre'" '[ $rc = 0 ] && holds 0x61' "$out"
out=$(printf '1\nYES\n' | run rollback 2>&1); rc=$?
check "rollback lists and reverts to 'pre update' (name with a space)" '[ $rc = 0 ] && grep -q "pre update" <<<"$out" && holds 0x62' "$out"
wipe
fill 0x71; for i in protect ssd1; do "$QI" snapshot -c A "$T/$i.qcow2"; done
fill 0x72; for i in protect ssd1; do "$QI" snapshot -c B "$T/$i.qcow2"; done
fill 0x73; for i in protect ssd1; do "$QI" snapshot -c A "$T/$i.qcow2"; done   # newer, same name as the oldest
fill 0x74
out=$(printf '2\nYES\n' | run rollback 2>&1); rc=$?
check "rollback cleanup keeps a newer snapshot whose name is shared with an older one" '[ $rc = 0 ] && holds 0x72 && grep -q "always kept" <<<"$out" && [ "$(tags protect)" = "A B A " ] && [ "$(tags ssd1)" = "A B A " ]' "$out"
wipe; run create H >/dev/null 2>&1
/opt/homebrew/bin/python3.14 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()" "$T/stale.sock"
conf "$T/stale.conf" "$T/stale.sock"
( exec 3<"$T/protect.qcow2"; exec sleep 30 ) & HOLD=$!; sleep 1
out=$(PROTECT_ON_MAC_CONF="$T/stale.conf" /bin/bash "$SNAP" create I 2>&1); rc=$?
check "QMP refused but an image is held open: refuse, do not go offline" '[ $rc != 0 ] && grep -q "still has" <<<"$out" && [ "$(tags protect)" = "H " ]' "$out"
kill $HOLD 2>/dev/null; wait $HOLD 2>/dev/null
out=$(PROTECT_ON_MAC_CONF="$T/stale.conf" /bin/bash "$SNAP" create I 2>&1); rc=$?
check "... and with no holder a stale socket means the VM is off (offline create)" '[ $rc = 0 ] && grep -q "not running" <<<"$out"' "$out"
echo "H" > "$T/.snapshot-restore-in-progress"
out=$(run create J 2>&1); rc=$?
check "an unfinished-restore marker blocks create" '[ $rc != 0 ] && grep -q "did not finish" <<<"$out"' "$out"
out=$(run list 2>&1)
check "... list warns about it" 'grep -q "did not finish" <<<"$out"' "$out"
out=$(printf 'YES\n' | run restore H 2>&1); rc=$?
check "... a restore is allowed and clears it" '[ $rc = 0 ] && [ ! -f "$T/.snapshot-restore-in-progress" ]' "$out"
run delete I >/dev/null 2>&1

# Round 3: backslashes in names made elsewhere; a root-owned leftover marker.
wipe
fill 0x81; for i in protect ssd1; do "$QI" snapshot -c 'a\b' "$T/$i.qcow2"; done
fill 0x82; for i in protect ssd1; do "$QI" snapshot -c 'a\\b' "$T/$i.qcow2"; done
fill 0x83
out=$(printf '1\nYES\n' | run rollback 2>&1); rc=$?
check "rollback to 'a\\\\b' reverts to that snapshot, not to 'a\\b'" '[ $rc = 0 ] && holds 0x82' "$out"
out=$(printf '2\nn\nYES\n' | run rollback 2>&1); rc=$?
check "rollback to 'a\\b' reverts to that snapshot" '[ $rc = 0 ] && holds 0x81' "$out"
wipe; run create K >/dev/null 2>&1; fill 0x84
echo K | sudo tee "$T/.snapshot-restore-in-progress" >/dev/null
out=$(printf 'YES\n' | run restore K 2>&1); rc=$?
check "a root-owned leftover marker does not block a restore, and is cleared" '[ $rc = 0 ] && [ ! -f "$T/.snapshot-restore-in-progress" ]' "$out"
run delete K >/dev/null 2>&1

# sudo with a stripped PATH, bad overrides.
run create F >/dev/null 2>&1
out=$(sudo -n /bin/bash "$SNAP" "$T/test.conf" list 2>&1); rc=$?
check "under sudo (stripped PATH, conf as first argument) list finds qemu-img" '[ $rc = 0 ] && grep -q " F " <<<"$out"' "$out"
out=$(QEMU_IMG=/nonexistent/qemu-img run list 2>&1); rc=$?
check "a bad QEMU_IMG override is an error" '[ $rc != 0 ] && grep -q "qemu-img not found" <<<"$out"' "$out"

# A QMP socket that accepts but never answers: must stop, quickly, not guess.
/opt/homebrew/bin/python3 - "$T/hung.sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(5)
conns = []
end = time.time() + 120
while time.time() < end:
    s.settimeout(1)
    try: conns.append(s.accept()[0])
    except socket.timeout: pass
PY
HUNG=$!; sleep 1
conf "$T/hung.conf" "$T/hung.sock"
t0=$(date +%s)
out=$(PROTECT_ON_MAC_CONF="$T/hung.conf" perl -e 'alarm 90; exec @ARGV' /bin/bash "$SNAP" create G 2>&1); rc=$?
dt=$(( $(date +%s) - t0 ))
check "a QMP socket that never answers stops create within ~15 s (was: 600 s, then guessed)" '[ $rc != 0 ] && grep -q "did not answer" <<<"$out" && [ $dt -lt 40 ] && [ -z "$(tags protect | grep -w G)" ]' "$out (took ${dt}s)"
out=$(printf 'YES\n' | PROTECT_ON_MAC_CONF="$T/hung.conf" perl -e 'alarm 90; exec @ARGV' /bin/bash "$SNAP" restore F 2>&1); rc=$?
check "... and stops restore" '[ $rc != 0 ] && grep -q "did not answer" <<<"$out"' "$out"
kill $HUNG 2>/dev/null; wait $HUNG 2>/dev/null

if [ -n "${REAL_CONF:-}" ]; then
# Running-VM refusal: throwaway images, REAL QMP socket. restore must stop at
# check_no_qemu_attached (QMP query-status only) before touching anything.
conf "$T/live.conf" "$(. "$REAL_CONF"; echo "${QMP_SOCKET:-/var/run/protect-vm.qmp.sock}")"
fill 0x78
out=$(printf 'YES\n' | PROTECT_ON_MAC_CONF="$T/live.conf" perl -e 'alarm 60; exec @ARGV' /bin/bash "$SNAP" restore F 2>&1); rc=$?
check "restore refuses while the VM answers QMP" '[ $rc != 0 ] && grep -q "the VM is running" <<<"$out" && holds 0x78' "$out"

# Read-only against the real VM and its real config.
REAL="$REAL_CONF"
out=$(perl -e 'alarm 60; exec @ARGV' /bin/bash "$SNAP" "$REAL" list 2>&1); rc=$?
check "real list reads both real images" '[ $rc = 0 ] && grep -q "=== .*protect.qcow2 ===" <<<"$out" && grep -q "=== .*ssd1.qcow2 ===" <<<"$out" && ! grep -q "could not read\|NOT FOUND" <<<"$out"' "$out"
out=$(perl -e 'alarm 60; exec @ARGV' /bin/bash "$SNAP" "$REAL" delete no-such-snapshot-xyz 2>&1); rc=$?
check "real delete of a missing tag is refused before any QMP job" '[ $rc != 0 ] && grep -q "no snapshot named" <<<"$out"' "$out"
else
    echo "SKIP  real-VM checks (set REAL_CONF to run them)"
fi

rm -rf "$T"
echo; echo "$pass passed, $fail failed"
