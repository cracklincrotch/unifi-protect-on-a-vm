#!/bin/bash
###############################################################################
# capture-storage-flow.sh
#
# Captures how a UniFi console drives storage from FRESH DISKS through to a
# configured array — the reference behaviour needed to make the VM's storage
# shim faithful. Run it on a REAL UNVR with disposable disks; the resulting
# capture is the contract the VM side (ustated-shim.js + ustorage-vm.py) must
# reproduce.
#
# It walks these phases, pausing for confirmation around the destructive ones:
#
#   0  preflight + discover ALL data disks + arrays + baseline snapshot
#   1  start packet capture (tcpdump on :11052 ustated and :10055 usd)
#   2  stop everything using /volume1, stop the arrays
#   3  WIPE every data disk  <-- destructive, gated behind an explicit prompt
#   4  restart the storage daemons + unifi-core (now seeing fresh disks)
#      and attach an execve strace to unifi-core
#   5  YOU complete the Storage setup in the browser; the script snapshots
#      ustorage state every 15s while you do
#   6  stop captures, collect journals, bundle everything into a tarball
#
#   *** PHASE 3 DESTROYS ALL DATA ON EVERY DATA DISK. ***
#   Only run this on a console whose disks hold nothing of value.
#
# It wipes EVERY non-OS whole disk it finds, so it works regardless of how many
# disks are installed and whether they are currently part of an array. To
# capture a specific scenario, install exactly the disks you want present and,
# in phase 5, pick the RAID level you want to test in the web UI.
#
# REQUIRES (root): tcpdump, mdadm, wipefs. Optional but recommended:
# sgdisk (gdisk) for a thorough GPT zap, strace to capture the exact
# ustorage/mdadm commands unifi-core invokes. Missing optionals degrade
# gracefully with a warning.
#
# USAGE
#   sudo ./capture-storage-flow.sh
#
# The capture lands at /tmp/storage-capture-<timestamp>.tar.gz — copy that
# off the console and hand it over for analysis.
###############################################################################
set -u

STORAGE_VOLUME=/volume1
PCAP_FILTER='port 11052 or port 10055'
# Storage daemons, stopped top-down and started bottom-up.
STORAGE_DAEMONS=(unifi-core ustated usdbd usd)

TS=$(date +%Y%m%d-%H%M%S)
START_EPOCH=$(date +%s)
OUTDIR=${OUTDIR:-/tmp/storage-capture-$TS}
TARBALL=/tmp/storage-capture-$TS.tar.gz

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

# systemd unit owning a PID, via its cgroup. Empty if not a service.
unit_of_pid() {
    local pid=$1
    [ -r "/proc/$pid/cgroup" ] || return 0
    grep -oE '[a-zA-Z0-9@._-]+\.service' "/proc/$pid/cgroup" 2>/dev/null | tail -1
}

# Parent whole disk of a block-device basename (partition -> its disk).
parent_disk() {
    local node=$1
    if [ -e "/sys/class/block/$node/partition" ]; then
        basename "$(dirname "$(realpath "/sys/class/block/$node")")"
    else
        echo "$node"
    fi
}

# Stop every systemd service holding a file open under /volume1.
stop_volume_users() {
    local round pids pid unit units
    for round in 1 2 3; do
        pids=$(fuser -m "$STORAGE_VOLUME" 2>/dev/null | tr -s ' ' '\n' \
               | grep -E '^[0-9]+$' || true)
        [ -z "$pids" ] && return 0
        units=""
        for pid in $pids; do
            unit=$(unit_of_pid "$pid")
            [ -n "$unit" ] && units="$units $unit"
        done
        units=$(echo "$units" | tr ' ' '\n' | sort -u | tr '\n' ' ')
        if [ -n "${units// /}" ]; then
            log "round $round: stopping volume users:$units"
            # shellcheck disable=SC2086
            systemctl stop $units 2>/dev/null
        fi
        sleep 3
    done
    # Anything still holding on after three rounds — name it, don't kill blindly.
    pids=$(fuser -m "$STORAGE_VOLUME" 2>/dev/null | tr -s ' ' '\n' \
           | grep -E '^[0-9]+$' || true)
    [ -n "$pids" ] && log "WARNING: still open after 3 rounds: PIDs $pids"
}

cleanup() {
    log "cleanup: stopping captures"
    [ -n "$TCPDUMP_PID" ]  && kill "$TCPDUMP_PID"  2>/dev/null
    [ -n "$STRACE_PID" ]   && kill "$STRACE_PID"   2>/dev/null
    [ -n "$SNAPLOOP_PID" ] && kill "$SNAPLOOP_PID" 2>/dev/null
}
trap cleanup EXIT

###############################################################################
# phase 0 — preflight + discovery
###############################################################################

[ "$(id -u)" -eq 0 ] || die "must run as root"
have tcpdump || die "tcpdump not found"
have mdadm   || die "mdadm not found"
have wipefs  || die "wipefs not found"
have ustorage || die "ustorage not found — run this on a UniFi console"
HAVE_SGDISK=0; have sgdisk && HAVE_SGDISK=1
HAVE_STRACE=0; have strace && HAVE_STRACE=1

mkdir -p "$OUTDIR/snapshots"
log "capture starting — output dir:"
log "  $OUTDIR"
[ "$HAVE_SGDISK" -eq 1 ] || log "NOTE: sgdisk absent — GPT zap falls back to wipefs only"
[ "$HAVE_STRACE" -eq 1 ] || log "NOTE: strace absent — execve log will not be captured"

# Identify the OS/boot disk so we never wipe it: the whole disk backing the
# UNVR data partition (/data), falling back to / .
OS_SRC=$(awk '$2=="/data"{print $1; exit}' /proc/self/mounts)
[ -n "$OS_SRC" ] || OS_SRC=$(awk '$2=="/"{print $1; exit}' /proc/self/mounts)
OS_DISK=""
[ -n "$OS_SRC" ] && [ -e "$OS_SRC" ] && OS_DISK=$(parent_disk "$(basename "$OS_SRC")")

# Data disks = every whole SATA/NVMe disk that is not the OS disk.
DISKS=""
for b in /sys/block/sd[a-z] /sys/block/sd[a-z][a-z] /sys/block/nvme*n[0-9]*; do
    [ -e "$b" ] || continue
    n=$(basename "$b")
    [ "$n" = "$OS_DISK" ] && continue
    # skip zero-size / non-physical entries
    sz=$(cat "$b/size" 2>/dev/null || echo 0)
    [ "$sz" -gt 0 ] || continue
    DISKS="$DISKS $n"
done
DISKS=$(echo "$DISKS" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
[ -n "${DISKS// /}" ] || die "no data disks found — nothing to capture"

# Build the disk set for membership tests.
declare -A DISK_SET=()
for d in $DISKS; do DISK_SET[$d]=1; done

# Every md array with at least one member on the data disks.
TARGET_MDS=""
for md in $(ls -d /sys/block/md* 2>/dev/null); do
    mdn=$(basename "$md")
    for m in $(ls "$md/slaves" 2>/dev/null); do
        if [ -n "${DISK_SET[$(parent_disk "$m")]:-}" ]; then
            TARGET_MDS="$TARGET_MDS $mdn"; break
        fi
    done
done
TARGET_MDS=$(echo "$TARGET_MDS" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')

# The array backing /volume1, if one is mounted (for the manifest only).
PRIMARY_MD=""
SRC=$(awk -v m="$STORAGE_VOLUME" '$2==m{print $1; exit}' /proc/self/mounts)
[ -n "$SRC" ] && PRIMARY_MD=$(basename "$SRC")

snapshot "phase0-baseline"
cp /proc/mdstat "$OUTDIR/mdstat.baseline" 2>/dev/null

echo
echo "######################################################################"
echo "# DISCOVERED:"
echo "#   OS disk (PRESERVED) : ${OS_DISK:-<unknown>}"
echo "#   /volume1 array      : ${PRIMARY_MD:-<none mounted>}"
echo "#   arrays to stop      :$TARGET_MDS"
echo "#   DATA DISKS TO WIPE  :$DISKS"
echo "#"
echo "# Phase 3 will DESTROY ALL DATA on:$DISKS"
echo "# Confirm the OS disk above is correct and NOT in the wipe list."
echo "######################################################################"
echo
read -r -p "Type the word ERASE to proceed, anything else to abort: " ANS
[ "$ANS" = "ERASE" ] || die "aborted by user"

###############################################################################
# phase 1 — start packet capture
###############################################################################

log "phase 1: starting tcpdump on loopback"
log "phase 1:   filter: $PCAP_FILTER"
tcpdump -i lo -s 0 -w "$OUTDIR/storage.pcap" $PCAP_FILTER \
    >"$OUTDIR/tcpdump.log" 2>&1 &
TCPDUMP_PID=$!
sleep 2
kill -0 "$TCPDUMP_PID" 2>/dev/null \
    || die "tcpdump failed to start — see tcpdump.log in output dir"
log "phase 1: tcpdump running (pid $TCPDUMP_PID) — recording"
sleep 5

###############################################################################
# phase 2 — stop services and arrays
###############################################################################

log "phase 2: stopping services that use $STORAGE_VOLUME"
stop_volume_users
for d in "${STORAGE_DAEMONS[@]}"; do
    log "phase 2: stopping $d"
    systemctl stop "$d" 2>/dev/null
done

log "phase 2: unmounting $STORAGE_VOLUME"
umount "$STORAGE_VOLUME" 2>/dev/null || umount -l "$STORAGE_VOLUME" 2>/dev/null

# swapoff anything backed by the target disks/arrays, then stop the arrays.
for sw in $(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null); do
    swn=$(basename "$sw")
    if echo " $TARGET_MDS " | grep -q " $swn " \
       || [ -n "${DISK_SET[$(parent_disk "$swn")]:-}" ]; then
        log "phase 2: swapoff $sw"
        swapoff "$sw" 2>/dev/null
    fi
done
for md in $TARGET_MDS; do
    log "phase 2: stopping array /dev/$md"
    if ! mdadm --stop "/dev/$md" 2>/dev/null; then
        log "WARNING: could not stop /dev/$md (still busy?)"
        log "  wipe will proceed anyway"
    fi
done
snapshot "phase2-services-down"

###############################################################################
# phase 3 — WIPE
###############################################################################

echo
echo "Phase 3 will WIPE:$DISKS"
read -r -p "Type ERASE to confirm wipe, anything else to abort: " ANS
[ "$ANS" = "ERASE" ] || die "aborted before wipe"

log "phase 3: wiping disks"
# Zero md superblocks on every member partition first.
for md in $TARGET_MDS; do
    for m in $(ls "/sys/block/$md/slaves" 2>/dev/null); do
        log "phase 3: mdadm --zero-superblock /dev/$m"
        mdadm --zero-superblock "/dev/$m" 2>/dev/null || true
    done
done
for disk in $DISKS; do
    log "phase 3: wipefs -a /dev/$disk"
    wipefs -a "/dev/$disk" 2>/dev/null || true
    if [ "$HAVE_SGDISK" -eq 1 ]; then
        log "phase 3: sgdisk --zap-all /dev/$disk"
        sgdisk --zap-all "/dev/$disk" 2>/dev/null || true
    fi
done
have partprobe && partprobe 2>/dev/null
sleep 2
snapshot "phase3-after-wipe"
log "phase 3: wipe complete — disks now appear unpartitioned"

###############################################################################
# phase 4 — restart storage stack, attach strace
###############################################################################

log "phase 4: restarting storage daemons + unifi-core"
for (( i=${#STORAGE_DAEMONS[@]}-1 ; i>=0 ; i-- )); do
    d=${STORAGE_DAEMONS[$i]}
    log "phase 4: starting $d"
    systemctl start "$d" 2>/dev/null \
        || log "NOTE: $d did not start (may be expected with no storage)"
done

# Wait for the unifi-core node process (process.title = unifi-core).
log "phase 4: waiting for unifi-core process"
UC_PID=""
for _ in $(seq 1 30); do
    UC_PID=$(pidof unifi-core 2>/dev/null | awk '{print $1}')
    [ -n "$UC_PID" ] && break
    sleep 1
done

if [ -n "$UC_PID" ] && [ "$HAVE_STRACE" -eq 1 ]; then
    log "phase 4: attaching execve strace to unifi-core (pid $UC_PID)"
    strace -f -tt -e trace=execve -p "$UC_PID" \
        -o "$OUTDIR/unifi-core-execve.strace" 2>/dev/null &
    STRACE_PID=$!
elif [ -z "$UC_PID" ]; then
    log "WARNING: unifi-core not found — execve strace skipped"
fi
snapshot "phase4-services-back-up"

###############################################################################
# phase 5 — operator completes Storage setup in the browser
###############################################################################

echo
echo "######################################################################"
echo "# Now open the console's web UI and complete the STORAGE SETUP flow:"
echo "#   - it should detect the fresh disks and prompt to configure storage"
echo "#   - pick the RAID level you want to capture and let it"
echo "#     create / format / sync the array"
echo "#"
echo "# This script is snapshotting ustorage state every 15s while you do."
echo "# Press ENTER here once the array shows CONFIGURED and HEALTHY."
echo "######################################################################"
( while :; do snapshot "phase5-during-setup"; sleep 15; done ) &
SNAPLOOP_PID=$!
read -r _ANS
kill "$SNAPLOOP_PID" 2>/dev/null; SNAPLOOP_PID=""
snapshot "phase5-final"

###############################################################################
# phase 6 — stop captures, collect journals, bundle
###############################################################################

log "phase 6: stopping captures"
[ -n "$TCPDUMP_PID" ] && kill "$TCPDUMP_PID" 2>/dev/null; TCPDUMP_PID=""
[ -n "$STRACE_PID" ]  && kill "$STRACE_PID"  2>/dev/null; STRACE_PID=""
sleep 1

log "phase 6: collecting journals since capture start"
for u in unifi-core ustated usd usdbd; do
    journalctl -u "$u" --since "@$START_EPOCH" --no-pager \
        > "$OUTDIR/$u.journal" 2>/dev/null || true
done

cat > "$OUTDIR/MANIFEST.txt" <<EOF
storage-flow capture — $TS
console: $(uname -n)   ucore: $(ustorage --version 2>/dev/null || echo '?')
/volume1 array: ${PRIMARY_MD:-<none>}   arrays stopped:$TARGET_MDS
OS disk preserved: ${OS_DISK:-<unknown>}   disks wiped:$DISKS

storage.pcap            tcpdump of :11052 (ustated) + :10055 (usd) — the wire
                        contract; decode against the storage/v1 .proto files.
unifi-core.journal      unifi-core log across the wipe + reconfigure.
ustated.journal         ustated log across the wipe + reconfigure.
usd.journal/usdbd.journal  storage daemon logs — usd.journal holds the actual
                        partition/RAID/mkfs provisioning sequence.
unifi-core-execve.strace exact ustorage/mdadm commands unifi-core invoked
                        (present only if strace was available).
snapshots/              ustorage disk/space/config + mdstat + lsblk, one
                        timestamped block per phase (see labels).
timeline.log            phase-by-phase timestamps for correlating the above.
mdstat.baseline         /proc/mdstat before anything was touched.

Phase labels in snapshots/: phase0-baseline, phase2-services-down,
phase3-after-wipe, phase4-services-back-up, phase5-during-setup (every 15s),
phase5-final.
EOF

log "phase 6: bundling"
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
