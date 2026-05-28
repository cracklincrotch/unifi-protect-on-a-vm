#!/bin/bash
###############################################################################
# capture-disk-event.sh
#
# NON-DESTRUCTIVE capture of disk hot-insert / hot-remove on a UniFi console.
# Records the storage wire traffic, the exact commands unifi-core invokes, and
# a rolling snapshot of ustorage / mdstat / lsblk state while YOU physically
# insert and remove disks. The capture is the reference for making the VM's
# storage shim react to disk events the way real hardware does.
#
# Unlike capture-storage-flow.sh this script TOUCHES NOTHING — it does not stop
# services, does not stop arrays, and does not wipe anything. It only observes.
# It is safe to run on a live console.
#
#   0  preflight + baseline snapshot
#   1  start packet capture (tcpdump :11052 ustated + :10055 usd), attach an
#      execve strace to the running unifi-core, start a 5s snapshot loop
#   2  YOU insert / remove disks; before each action you type a short label so
#      the timeline records what happened when. Type 'done' when finished.
#   3  stop captures, collect journals, bundle into a tarball
#
# WHAT TO CAPTURE (suggestions — do as many as you like in one run):
#   - insert a disk into an EMPTY bay        (pure detection / SMART probe)
#   - remove that same disk                  (clean removal)
#   - remove a disk that is an ARRAY MEMBER  (array degradation)
#   - re-insert that array member            (re-add / rebuild)
# Give each its own label so the events are easy to separate later.
#
# REQUIRES (root): tcpdump. Optional: strace (exact unifi-core commands).
#
# USAGE
#   sudo ./capture-disk-event.sh
#
# The capture lands at /tmp/disk-event-capture-<timestamp>.tar.gz — copy that
# off the console and hand it over for analysis.
###############################################################################
set -u

PCAP_FILTER='port 11052 or port 10055'
SNAP_INTERVAL=5

TS=$(date +%Y%m%d-%H%M%S)
START_EPOCH=$(date +%s)
OUTDIR=${OUTDIR:-/tmp/disk-event-capture-$TS}
TARBALL=/tmp/disk-event-capture-$TS.tar.gz

TCPDUMP_PID=""
STRACE_PID=""
SNAPLOOP_PID=""

###############################################################################
# helpers
###############################################################################

log() {
    local line="[capture $(date +%H:%M:%S)] $*"
    echo "$line"
    [ -d "$OUTDIR" ] && echo "$line" >> "$OUTDIR/timeline.log"
}
die()  { echo "[capture] FATAL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Append a timestamped snapshot of all storage state under one label.
snapshot() {
    local label="$*" d="$OUTDIR/snapshots"
    mkdir -p "$d"
    local hdr="=== $label  $(date -Is) ==="
    { echo "$hdr"; ustorage disk inspect  2>&1; echo; } >> "$d/ustorage-disk.log"
    { echo "$hdr"; ustorage space inspect 2>&1; echo; } >> "$d/ustorage-space.log"
    { echo "$hdr"; ustorage config show   2>&1; echo; } >> "$d/ustorage-config.log"
    { echo "$hdr"; cat /proc/mdstat       2>&1; echo; } >> "$d/mdstat.log"
    { echo "$hdr"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL,UUID 2>&1; echo; } \
        >> "$d/lsblk.log"
}

cleanup() {
    log "cleanup: stopping captures"
    [ -n "$SNAPLOOP_PID" ] && kill "$SNAPLOOP_PID" 2>/dev/null
    [ -n "$TCPDUMP_PID" ]  && kill "$TCPDUMP_PID"  2>/dev/null
    [ -n "$STRACE_PID" ]   && kill "$STRACE_PID"   2>/dev/null
}
trap cleanup EXIT

###############################################################################
# phase 0 — preflight + baseline
###############################################################################

[ "$(id -u)" -eq 0 ] || die "must run as root"
have tcpdump  || die "tcpdump not found"
have ustorage || die "ustorage not found — run this on a UniFi console"
HAVE_STRACE=0; have strace && HAVE_STRACE=1

mkdir -p "$OUTDIR/snapshots"
log "capture starting — output dir:"
log "  $OUTDIR"
[ "$HAVE_STRACE" -eq 1 ] || log "NOTE: strace absent — execve log will not be captured"

snapshot "phase0-baseline"
cp /proc/mdstat "$OUTDIR/mdstat.baseline" 2>/dev/null

###############################################################################
# phase 1 — start captures
###############################################################################

log "phase 1: starting tcpdump on loopback"
log "phase 1:   filter: $PCAP_FILTER"
tcpdump -i lo -s 0 -w "$OUTDIR/storage.pcap" $PCAP_FILTER \
    >"$OUTDIR/tcpdump.log" 2>&1 &
TCPDUMP_PID=$!
sleep 2
kill -0 "$TCPDUMP_PID" 2>/dev/null \
    || die "tcpdump failed to start — see tcpdump.log in output dir"
log "phase 1: tcpdump running (pid $TCPDUMP_PID)"

# unifi-core is already running on a live console — attach straight away.
UC_PID=$(pidof unifi-core 2>/dev/null | awk '{print $1}')
if [ -n "$UC_PID" ] && [ "$HAVE_STRACE" -eq 1 ]; then
    log "phase 1: attaching execve strace to unifi-core (pid $UC_PID)"
    strace -f -tt -e trace=execve -p "$UC_PID" \
        -o "$OUTDIR/unifi-core-execve.strace" 2>/dev/null &
    STRACE_PID=$!
elif [ -z "$UC_PID" ]; then
    log "WARNING: unifi-core not found — execve strace skipped"
fi

# Rolling background snapshot every SNAP_INTERVAL seconds.
( while :; do snapshot "tick"; sleep "$SNAP_INTERVAL"; done ) &
SNAPLOOP_PID=$!
log "phase 1: snapshot loop running every ${SNAP_INTERVAL}s"
sleep 5

###############################################################################
# phase 2 — operator inserts / removes disks
###############################################################################

echo
echo "######################################################################"
echo "# DISK EVENT CAPTURE — the script is now recording."
echo "#"
echo "# For each disk action:"
echo "#   1. type a short label describing what you are ABOUT to do"
echo "#      (e.g. 'insert-bay3', 'remove-sdc', 'remove-array-member-sdb')"
echo "#   2. press ENTER — the script timestamps and snapshots"
echo "#   3. physically perform the action"
echo "#   4. wait ~10s for the console to react, then start the next one"
echo "#"
echo "# Type 'done' when you have finished all actions."
echo "######################################################################"
echo

n=0
while :; do
    read -r -p "next action label (or 'done'): " LABEL
    [ "$LABEL" = "done" ] && break
    [ -z "$LABEL" ] && continue
    n=$((n+1))
    safe=$(echo "$LABEL" | tr -c 'A-Za-z0-9._-' '_')
    log "event $n: $LABEL — perform the action now"
    snapshot "event${n}-${safe}-mark"
done
log "phase 2: operator reported $n event(s) complete"

###############################################################################
# phase 3 — stop captures, collect journals, bundle
###############################################################################

log "phase 3: stopping captures"
[ -n "$SNAPLOOP_PID" ] && kill "$SNAPLOOP_PID" 2>/dev/null; SNAPLOOP_PID=""
[ -n "$TCPDUMP_PID" ]  && kill "$TCPDUMP_PID"  2>/dev/null; TCPDUMP_PID=""
[ -n "$STRACE_PID" ]   && kill "$STRACE_PID"   2>/dev/null; STRACE_PID=""
sleep 1
snapshot "phase3-final"

log "phase 3: collecting journals since capture start"
for u in unifi-core ustated usd usdbd; do
    journalctl -u "$u" --since "@$START_EPOCH" --no-pager \
        > "$OUTDIR/$u.journal" 2>/dev/null || true
done

cat > "$OUTDIR/MANIFEST.txt" <<EOF
disk-event capture — $TS
console: $(uname -n)   ucore: $(ustorage --version 2>/dev/null || echo '?')
events recorded: $n   (non-destructive — no wipe, no service stop)

storage.pcap            tcpdump of :11052 (ustated) + :10055 (usd) — the wire
                        traffic, incl. usd HardwareEvents/StorageEvents on hot-plug.
unifi-core.journal      unifi-core log across the disk events.
ustated.journal         ustated log across the disk events.
usd.journal/usdbd.journal  storage daemon logs — usd.journal shows how usd
                        reacts to a disk appearing/disappearing.
unifi-core-execve.strace exact ustorage/mdadm commands unifi-core invoked
                        (present only if strace was available).
snapshots/              ustorage disk/space/config + mdstat + lsblk. 'tick'
                        blocks every ${SNAP_INTERVAL}s; 'eventN-<label>-mark'
                        blocks pin each operator action.
timeline.log            timestamps for every event + tick, for correlation.
mdstat.baseline         /proc/mdstat before anything was touched.
EOF

log "phase 3: bundling"
tar czf "$TARBALL" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")" 2>/dev/null \
    || die "failed to create $TARBALL"

echo
echo "######################################################################"
echo "# Capture complete."
echo "#   tarball : $TARBALL"
echo "#   raw dir : $OUTDIR"
echo "#"
echo "# Copy the tarball off this console for analysis."
echo "######################################################################"
echo
