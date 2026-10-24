#!/bin/bash
# Tests for the `snapshot` verb of host/control-host-helper.sh. Runs on macOS
# (bash 3.2) or Linux, as any user, with no VM: requests go through the
# helper's own __serve loop, and sudo, snapshot.sh and python3 are stubs that
# record how they were called.
#   Part 1: stubbed snapshot.sh - the exact sudo command line, the conf
#           passed as the first argument, idempotency and errors passed
#           through, label checks, the channel's stdin left alone.
#   Part 2: the REAL snapshot.sh against throwaway qcow2 images (its offline
#           path), when a qemu-img with `snapshot -f` (QEMU 9 or later) is
#           found; skipped otherwise.
#   Part 3: opt-in and read-only. REAL_CONF=/path/to/protect-on-mac.conf runs
#           `sudo -n snapshot.sh <conf> list`, with the real sudo, to show the
#           NOPASSWD rule the verb depends on is in place. Nothing is created:
#           never send a snapshot request to the real VM from a test.
# usage: test_control_host_helper.sh [/path/to/control-host-helper.sh]
HELPER="${1:-$(cd "$(dirname "$0")/.." && pwd)/control-host-helper.sh}"
REPO_HOST="$(cd "$(dirname "$HELPER")" && pwd)"
T=$(mktemp -d /tmp/ctltest.XXXX)
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; echo "$2" | head -10 | sed 's/^/      /'; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$3"; fi; }

mkdir -p "$T/host" "$T/bin" "$T/vm-data"
cp "$HELPER" "$T/host/control-host-helper.sh"
CONF="$T/vm-data/protect-on-mac.conf"
cat > "$CONF" <<EOF
VM_DATA_DIR="$T/vm-data"
EOF

# sudo: records its arguments; resets the environment the way sudo's
# env_reset does, unless SUDO_KEEPS_ENV is set (sudoers env_keep / -E).
cat > "$T/bin/sudo" <<EOF
#!/bin/bash
echo "\$*" >> "$T/sudo.log"
[ "\$1" = -n ] && shift
[ "\$1" = -u ] && shift 2
if [ -n "\${SUDO_KEEPS_ENV:-}" ]; then exec "\$@"; fi
exec env -i PATH="\$PATH" HOME="\$HOME" "\$@"
EOF
# python3: the old vm-snapshot.py route. Must no longer be taken.
cat > "$T/bin/python3" <<EOF
#!/bin/sh
echo "python3 \$*" >> "$T/python3.log"
exit 1
EOF
# snapshot.sh stand-in: records argv, PROTECT_ON_MAC_CONF and any stdin,
# then answers as the real one does for the scenario in $T/mode.
cat > "$T/host/snapshot.sh" <<EOF
#!/bin/bash
{ echo "argv:\$*"; echo "env:\${PROTECT_ON_MAC_CONF-unset}"; } >> "$T/snap.log"
if read -r -t 1 line; then echo "stdin:\$line" >> "$T/snap.log"; fi
[ -f "\$1" ] && [ "\${1##*.}" = conf ] && shift
case "\$(cat "$T/mode")" in
    create)  echo "Snapshot '\$2' created on all 2 images."; exit 0 ;;
    exists)  echo "Snapshot '\$2' already exists - left as-is."; exit 0 ;;
    partial) echo "ERROR: snapshot '\$2' already exists on 1 of 2 images." >&2; exit 1 ;;
    norule)  echo "sudo: a password is required" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/sudo" "$T/bin/python3" "$T/host/snapshot.sh"

# serve <helper> <request lines...>: one channel session through __serve.
serve() {
    local h="$1"; shift
    printf '%s\n' "$@" | PATH="$T/bin:$PATH" PROTECT_ON_MAC_CONF="$CONF" bash "$h" __serve 2>&1
}
H="$T/host/control-host-helper.sh"
reset() { rm -f "$T/sudo.log" "$T/snap.log"; }
rc_of() { sed -n 's/^__PROTECT_CTL_DONE //p' <<<"$1" | tail -1; }

###############################################################################
# Part 1: stubbed snapshot.sh
###############################################################################

echo create > "$T/mode"; reset
out=$(serve "$H" "snapshot fresh-debian")
check "snapshot runs 'sudo -n <host>/snapshot.sh <conf> create <label>'" '[ "$(rc_of "$out")" = 0 ] && [ "$(cat "$T/sudo.log")" = "-n $T/host/snapshot.sh $CONF create fresh-debian" ]' "$out
$(cat "$T/sudo.log" 2>/dev/null)"
check "... snapshot.sh gets the conf as its first argument, the environment stripped" 'grep -qx "argv:$CONF create fresh-debian" "$T/snap.log" && grep -qx "env:unset" "$T/snap.log"' "$(cat "$T/snap.log" 2>/dev/null)"
check "... and its answer comes back over the channel" 'grep -q "created on all 2 images" <<<"$out"' "$out"

echo exists > "$T/mode"; reset
out=$(serve "$H" "snapshot fresh-debian")
check "an existing snapshot: 'already exists - left as-is', exit 0" '[ "$(rc_of "$out")" = 0 ] && grep -q "already exists - left as-is" <<<"$out"' "$out"
echo partial > "$T/mode"; reset
out=$(serve "$H" "snapshot fresh-debian")
check "a snapshot on only some images: the error and a non-zero exit come back" '[ "$(rc_of "$out")" = 1 ] && grep -q "on 1 of 2 images" <<<"$out"' "$out"
echo norule > "$T/mode"; reset
out=$(serve "$H" "snapshot fresh-debian")
check "a sudo failure is reported, not hidden" '[ "$(rc_of "$out")" = 1 ] && grep -q "password is required" <<<"$out"' "$out"

echo create > "$T/mode"; reset
out=$(SUDO_KEEPS_ENV=1 serve "$H" "snapshot fresh-debian")
check "where sudo keeps the environment, snapshot.sh sees it empty and still takes the conf" '[ "$(rc_of "$out")" = 0 ] && grep -qx "env:" "$T/snap.log" && grep -qx "argv:$CONF create fresh-debian" "$T/snap.log"' "$out
$(cat "$T/snap.log" 2>/dev/null)"

reset
out=$(serve "$H" "snapshot pre-1" "ping" "snapshot pre-2")
check "snapshot.sh does not read the channel: the next requests still arrive" '[ "$(grep -c "^__PROTECT_CTL_DONE 0" <<<"$out")" = 3 ] && grep -qx pong <<<"$out" && ! grep -q "^stdin:" "$T/snap.log" && [ "$(grep -c "^argv:" "$T/snap.log")" = 2 ]' "$out
$(cat "$T/snap.log" 2>/dev/null)"

long=$(printf 'a%.0s' $(seq 1 65))
for req in "snapshot" "snapshot a;b" 'snapshot $(id)' "snapshot ../x" "snapshot a/b" "snapshot $long"; do
    reset; out=$(serve "$H" "$req")
    check "refused before sudo: '${req:0:30}'" '[ "$(rc_of "$out")" = 64 ] && [ ! -e "$T/sudo.log" ]' "$out"
done
reset; out=$(serve "$H" "snapshot $(printf 'a%.0s' $(seq 1 64))")
check "a 64-character label is accepted" '[ "$(rc_of "$out")" = 0 ] && [ -e "$T/sudo.log" ]' "$out"

mv "$CONF" "$CONF.away"; reset
out=$(printf 'snapshot x\n' | PATH="$T/bin:$PATH" PROTECT_ON_MAC_CONF="$CONF" bash "$H" __serve 2>&1)
check "a missing conf is refused before sudo (exit 69)" '[ "$(rc_of "$out")" = 69 ] && grep -q "not found" <<<"$out" && [ ! -e "$T/sudo.log" ]' "$out"
mv "$CONF.away" "$CONF"
cp "$CONF" "$T/vm-data/protect.cfg"; reset
out=$(printf 'snapshot x\n' | PATH="$T/bin:$PATH" PROTECT_ON_MAC_CONF="$T/vm-data/protect.cfg" bash "$H" __serve 2>&1)
check "a conf snapshot.sh would not take (not *.conf) is refused before sudo (exit 69)" '[ "$(rc_of "$out")" = 69 ] && grep -q "does not end in .conf" <<<"$out" && [ ! -e "$T/sudo.log" ]' "$out"
chmod -x "$T/host/snapshot.sh"; reset
out=$(serve "$H" "snapshot x")
check "a missing snapshot.sh is refused before sudo (exit 69)" '[ "$(rc_of "$out")" = 69 ] && [ ! -e "$T/sudo.log" ]' "$out"
chmod +x "$T/host/snapshot.sh"

check "vm-snapshot.py (python3 under sudo) is never run" '[ ! -e "$T/python3.log" ]' "$(cat "$T/python3.log" 2>/dev/null)"

###############################################################################
# Part 2: the real snapshot.sh, offline, on throwaway images
###############################################################################

QI="${QEMU_IMG:-$(command -v qemu-img 2>/dev/null || echo /opt/homebrew/bin/qemu-img)}"
supported() {
    [ -x "$QI" ] && "$QI" create -q -f qcow2 "$T/probe.qcow2" 1M >/dev/null 2>&1 \
        && "$QI" snapshot -f qcow2 -l "$T/probe.qcow2" >/dev/null 2>&1
}
if [ -f "$REPO_HOST/snapshot.sh" ] && supported; then
    mkdir -p "$T/real"
    cp "$H" "$REPO_HOST/snapshot.sh" "$T/real/"
    R="$T/real/control-host-helper.sh"
    for i in protect ssd1; do "$QI" create -q -f qcow2 "$T/vm-data/$i.qcow2" 16M; done
    cat >> "$CONF" <<EOF
VM_DISK="$T/vm-data/protect.qcow2"
SSD_IMAGE="$T/vm-data/ssd1.qcow2"
STORAGE_IMAGES=()
QMP_SOCKET="$T/no-such.sock"
QEMU_IMG="$QI"
EOF
    count() { "$QI" snapshot -l -U "$T/vm-data/$1.qcow2" | awk -v t="$2" 'NR > 2 && $2 == t' | wc -l | tr -d ' '; }
    reset; out=$(serve "$R" "snapshot fresh-debian")
    check "real snapshot.sh: a new label is created on BOTH images" '[ "$(rc_of "$out")" = 0 ] && [ "$(count protect fresh-debian)" = 1 ] && [ "$(count ssd1 fresh-debian)" = 1 ]' "$out"
    out=$(serve "$R" "snapshot fresh-debian")
    check "real snapshot.sh: asked again, 'already exists - left as-is', exit 0, still one each" '[ "$(rc_of "$out")" = 0 ] && grep -q "already exists" <<<"$out" && [ "$(count protect fresh-debian)" = 1 ] && [ "$(count ssd1 fresh-debian)" = 1 ]' "$out"
    out=$(serve "$R" "snapshot fresh")
    check "real snapshot.sh: 'fresh' is not mistaken for 'fresh-debian' (the old grep -w)" '[ "$(rc_of "$out")" = 0 ] && [ "$(count protect fresh)" = 1 ] && [ "$(count ssd1 fresh)" = 1 ]' "$out"
    "$QI" snapshot -c half "$T/vm-data/ssd1.qcow2"
    out=$(serve "$R" "snapshot half")
    check "real snapshot.sh: a label on 1 of 2 images is refused, not topped up" '[ "$(rc_of "$out")" != 0 ] && grep -q "on 1 of 2 images" <<<"$out" && [ "$(count protect half)" = 0 ]' "$out"
    out=$(serve "$R" "snapshot 12345")
    check "real snapshot.sh: an all-digit label is refused" '[ "$(rc_of "$out")" != 0 ] && grep -q "all digits" <<<"$out"' "$out"
else
    echo "SKIP  real snapshot.sh checks (need a qemu-img with 'snapshot -f'; set QEMU_IMG)"
fi

###############################################################################
# Part 3: opt-in, read-only, real sudo
###############################################################################

if [ -n "${REAL_CONF:-}" ]; then
    out=$(perl -e 'alarm 60; exec @ARGV' sudo -n "$REPO_HOST/snapshot.sh" "$REAL_CONF" list </dev/null 2>&1); rc=$?
    check "real: 'sudo -n snapshot.sh <conf> list' runs without a password and reads the images" '[ $rc = 0 ] && grep -q "^=== .*qcow2 ===" <<<"$out" && ! grep -q "could not read\|NOT FOUND" <<<"$out"' "$out"
else
    echo "SKIP  real sudo check (set REAL_CONF to run it; read-only)"
fi

rm -rf "$T"
echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
