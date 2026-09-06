#!/bin/bash
###############################################################################
# das-marker-partition.sh — give each data disk one partition macOS can read.
#
# OPTIONAL. Run INSIDE the guest, AFTER the array exists. Dry-run by default.
#
# THE PROBLEM
#
# The data disks carry only Linux partitions, so macOS can mount nothing on
# them and Disk Arbitration raises
#
#     "The disk you attached was not readable by this computer.
#      Eject / Initialize... / Ignore"
#
# once per disk, every time QEMU releases the disks — i.e. on every VM restart.
# Four disks, four dialogs, stacking up unattended. That is not cosmetic: the
# Initialize... button destroys an array member, and it sits next to Ignore.
#
# THE FIX
#
# The dialog is raised PER DISK, when NOTHING on the whole device is mountable —
# not per partition. (Four disks with four unreadable Linux partitions each
# produce four dialogs, not sixteen.) So one small readable partition per disk
# is enough to silence it, and the other partitions can stay exactly as they
# are. This script adds that partition; the host side formats it and marks it
# noauto — see host/das-marker-format.sh, which MUST be run afterwards, because
# an unformatted partition silences nothing.
#
# WHY IT IS SAFE
#
#   - It only ever uses space that is ALREADY UNALLOCATED. Nothing is shrunk,
#     moved or repurposed, so no existing partition is touched and there is no
#     data to lose. UniFi's layout leaves gaps: on 7.1/5.1 there is ~511MiB
#     between partitions 1 and 2, and ~4GiB further along.
#   - It uses `sfdisk --append`, which adds an entry without rewriting the
#     existing ones.
#   - It picks the SMALLEST gap that is big enough. That matters: the large gap
#     sits where a partition 4 would go — the partition numbering skips 4 —
#     so it is almost certainly reserved by UniFi, and taking the smallest
#     suitable gap structurally avoids it. MAX_GAP_MIB refuses a gap that is
#     suspiciously large for the same reason.
#   - It assigns the lowest free partition number >= 6, leaving 4 alone.
#
# THE RISK THAT REMAINS, STATED PLAINLY
#
# Nobody has verified how a real UniFi NVR reacts to an extra partition on its
# disks. It may ignore it, or it may re-provision. Undo is simply deleting the
# partition (the space was never allocated to anything), but if you intend to
# put these disks back into real hardware, know that this is unproven.
#
# USAGE
#   das-marker-partition.sh                 # dry run, show what it would do
#   das-marker-partition.sh --yes           # actually write
#   das-marker-partition.sh --yes --disk sda
###############################################################################
set -u

MIN_GAP_MIB="${MIN_GAP_MIB:-64}"     # a FAT16 filesystem needs little room
MAX_GAP_MIB="${MAX_GAP_MIB:-1024}"   # refuse a big gap: probably reserved
TYPE_MSDATA="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

APPLY=0
ONLY_DISK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)  APPLY=1 ;;
        --disk)    shift; ONLY_DISK="${1:-}" ;;
        -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" = "0" ] || { echo "must run as root" >&2; exit 1; }

# Only disks that actually carry an md member — that is what makes a disk one
# of ours rather than something else plugged into the same machine.
das_disks() {
    local d
    for d in /sys/block/sd*; do
        [ -d "$d" ] || continue
        d=$(basename "$d")
        if lsblk -no FSTYPE "/dev/$d" 2>/dev/null | grep -q linux_raid_member; then
            echo "$d"
        fi
    done
}

plan_for_disk() {
    # prints: <part_number> <start_sector> <size_sectors> <gap_mib>
    local disk="$1"
    sfdisk -d "/dev/$disk" 2>/dev/null | python3 - "$MIN_GAP_MIB" "$MAX_GAP_MIB" <<'PY'
import re, sys
min_mib, max_mib = int(sys.argv[1]), int(sys.argv[2])
text = sys.stdin.read()
first = int(re.search(r'first-lba:\s*(\d+)', text).group(1))
last  = int(re.search(r'last-lba:\s*(\d+)',  text).group(1))
parts, nums = [], set()
for line in text.splitlines():
    m = re.match(r'^(\S*?)(\d+)\s*:\s*start=\s*(\d+),\s*size=\s*(\d+)', line)
    if m:
        nums.add(int(m.group(2)))
        parts.append((int(m.group(3)), int(m.group(4))))
parts.sort()

ALIGN = 2048                                   # 1MiB
gaps = []
cur = first
for start, size in parts:
    if start > cur:
        gaps.append((cur, start - 1))
    cur = max(cur, start + size)
if last > cur:
    gaps.append((cur, last))

best = None
for lo, hi in gaps:
    s = ((lo + ALIGN - 1) // ALIGN) * ALIGN     # align the start up
    e = ((hi + 1) // ALIGN) * ALIGN - 1         # align the end down
    if e <= s:
        continue
    mib = (e - s + 1) // 2048
    if mib < min_mib or mib > max_mib:
        continue
    # smallest suitable gap wins -- the big ones are likely reserved
    if best is None or mib < best[2]:
        best = (s, e - s + 1, mib)

if best is None:
    sys.exit(1)
num = 6                                        # leave 4 alone: likely UniFi's
while num in nums:
    num += 1
print("%d %d %d %d" % (num, best[0], best[1], best[2]))
PY
}

rc=0
for disk in $(das_disks); do
    [ -n "$ONLY_DISK" ] && [ "$disk" != "$ONLY_DISK" ] && continue

    if lsblk -no PARTTYPE "/dev/$disk" 2>/dev/null | grep -qi "$TYPE_MSDATA"; then
        echo "$disk: already has a marker partition — nothing to do"
        continue
    fi

    plan=$(plan_for_disk "$disk")
    if [ -z "$plan" ]; then
        echo "$disk: no unallocated gap between ${MIN_GAP_MIB}MiB and ${MAX_GAP_MIB}MiB — SKIPPED" >&2
        rc=1
        continue
    fi
    set -- $plan
    num="$1"; start="$2"; size="$3"; mib="$4"

    if [ "$APPLY" = "0" ]; then
        printf '%s: would create partition %s at sector %s, %s sectors (%sMiB)\n' \
            "$disk" "$num" "$start" "$size" "$mib"
        continue
    fi

    echo "$disk: creating partition $num at $start (${mib}MiB)"
    # --append adds an entry; the existing ones are not rewritten. Re-reading
    # the table fails while md holds members ("Device or resource busy") --
    # that is expected and harmless, because the on-disk GPT is what the host
    # reads, and the new partition is in space nothing was using.
    if printf 'start=%s, size=%s, type=%s\n' "$start" "$size" "$TYPE_MSDATA" \
        | sfdisk --append --no-reread --no-tell-kernel "/dev/$disk" >/dev/null 2>&1; then
        partx -a "/dev/$disk" >/dev/null 2>&1 || true
        echo "$disk: partition $num created"
    else
        echo "$disk: sfdisk --append FAILED" >&2
        rc=1
    fi
done

if [ "$APPLY" = "0" ]; then
    echo ""
    echo "Dry run. Re-run with --yes to write, then run host/das-marker-format.sh"
    echo "on the macOS host WITH THE VM SHUT DOWN — an unformatted partition"
    echo "silences nothing."
fi
exit $rc
