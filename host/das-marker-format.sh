#!/bin/bash
###############################################################################
# das-marker-format.sh — format the DAS marker partitions and keep them unmounted.
#
# OPTIONAL, macOS side. RUN WITH THE PROTECT VM SHUT DOWN. Dry-run by default.
#
# Second half of the pair; the first is vm/storage/.../das-marker-partition.sh,
# which creates one small partition per data disk out of already-unallocated
# space. This formats them FAT and marks them noauto in /etc/fstab. Both halves
# are needed:
#
#   - unformatted, macOS still finds nothing mountable and still raises
#     "The disk you attached was not readable by this computer" per disk, whose
#     Initialize... button destroys an array member;
#   - formatted but auto-mounting, QEMU refuses to open the disk at all --
#     "If device /dev/diskN is mounted on the desktop, unmount it first before
#     using it in QEMU" -- and the VM will not start.
#
# So the goal is precisely: RECOGNISED, NEVER MOUNTED. macOS probes the
# filesystem (no dialog) and fstab stops it being mounted (QEMU keeps the disk).
#
# WHY THE VM MUST BE DOWN
#
# While QEMU holds a disk, macOS does not even parse its partition table --
# `diskutil list` shows the GUID_partition_scheme and nothing else. The
# partitions only become visible, and formattable, once QEMU lets go.
#
# SAFETY
#
# Every candidate must pass ALL of: on a disk whose serial appears in the
# launcher's disk-serial.map; partition type "Microsoft Basic Data"; size within
# MARKER_MAX_MIB; and NO existing filesystem. Anything else is skipped, loudly.
# It will not reformat a partition that already has a filesystem, so re-running
# is safe.
#
# USAGE
#   ./das-marker-format.sh                # dry run
#   ./das-marker-format.sh --yes          # format + write fstab
###############################################################################
set -u

VM_DATA_DIR="${VM_DATA_DIR:-$(cd "$(dirname "$0")/.." && pwd)/vm-data}"
DISK_MAP="${DISK_MAP:-$VM_DATA_DIR/disk-serial.map}"
MARKER_MAX_MIB="${MARKER_MAX_MIB:-1024}"
FSTAB=/etc/fstab
BEGIN_MARK="# BEGIN protect-on-mac DAS markers"
END_MARK="# END protect-on-mac DAS markers"

APPLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)  APPLY=1 ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

if pgrep -f "qemu-system-aarch64 -machine virt" >/dev/null 2>&1; then
    echo "ERROR: the Protect VM is running. Shut it down first — while QEMU" >&2
    echo "       holds the disks macOS cannot see their partitions at all." >&2
    exit 1
fi

[ -r "$DISK_MAP" ] || { echo "ERROR: no disk map at $DISK_MAP" >&2; exit 1; }
KNOWN=$(awk -F'\t' '$2=="disk" {print $1}' "$DISK_MAP")
[ -n "$KNOWN" ] || { echo "ERROR: no raw disks listed in $DISK_MAP" >&2; exit 1; }
echo "Data disks from the map: $(echo $KNOWN | tr '\n' ' ')"

serial_of() {
    smartctl -j -a "$1" 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("serial_number",""))' 2>/dev/null
}

formatted=0
MARKERS=""
for whole in $(diskutil list 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external, physical\)/{print $1}'); do
    ser=$(serial_of "$whole")
    echo "$KNOWN" | grep -qw "$ser" || continue

    part=$(diskutil list "$whole" 2>/dev/null | awk '/Microsoft Basic Data/{print $NF}' | head -1)
    if [ -z "$part" ]; then
        echo "  $whole ($ser): no marker partition — run das-marker-partition.sh in the guest first" >&2
        continue
    fi
    info=$(diskutil info "/dev/$part" 2>/dev/null)
    ptype=$(printf '%s' "$info" | awk -F': *' '/Partition Type/{print $2}' | head -1)
    bytes=$(printf '%s' "$info" | awk -F'[()]' '/Disk Size/{print $2}' | head -1 | awk '{print $1}')
    fs=$(printf '%s' "$info" | awk -F': *' '/File System Personality/{print $2}' | head -1)
    mib=$(( ${bytes:-0} / 1048576 ))

    case "$ptype" in *Microsoft*Basic*Data*) ;; *)
        echo "  /dev/$part: type is '$ptype', not Microsoft Basic Data — SKIPPED" >&2; continue;; esac
    if [ "$mib" -gt "$MARKER_MAX_MIB" ]; then
        echo "  /dev/$part: ${mib}MiB exceeds MARKER_MAX_MIB=${MARKER_MAX_MIB} — SKIPPED" >&2; continue
    fi

    # "File System Personality" can be inferred from the partition TYPE alone,
    # so it is not proof a filesystem exists. Mountability is.
    if diskutil mount "/dev/$part" >/dev/null 2>&1; then
        diskutil unmount "/dev/$part" >/dev/null 2>&1
        echo "  /dev/$part ($ser): already formatted — leaving alone"
    elif [ "$APPLY" = "0" ]; then
        echo "  /dev/$part ($ser): would format FAT, label $ser (${mib}MiB)"
    else
        echo "  /dev/$part ($ser): formatting FAT, label $ser"
        if newfs_msdos -v "$ser" "/dev/$part" >/dev/null 2>&1; then
            formatted=$((formatted + 1))
        else
            echo "  /dev/$part: newfs_msdos FAILED" >&2
            continue
        fi
    fi

    sleep 1
    uuid=$(diskutil info "/dev/$part" 2>/dev/null | awk -F': *' '/Volume UUID/{print $2}' | head -1)
    if [ -n "$uuid" ]; then
        MARKERS="$MARKERS$uuid $ser
"
    fi
done

if [ -z "$MARKERS" ]; then
    echo "No marker volumes found; nothing to write to $FSTAB."
    [ "$APPLY" = "0" ] && echo "(dry run — re-run with --yes)"
    exit 0
fi

block="$BEGIN_MARK
#
# Marker partitions on the UniFi data disks: one small FAT filesystem per disk
# so macOS finds something mountable and stops raising its unreadable-disk
# dialog (whose Initialize... button destroys an array member).
#
# They must stay UNMOUNTED. QEMU refuses a whole disk that has any mounted
# volume, so mounting one of these stops the VM from starting. Labels are the
# drive serials, so a mount point always names its disk.
#
# Managed by host/das-marker-format.sh — edits between these markers are lost.
$END_MARK"
lines=""
while read -r u l; do
    [ -n "$u" ] || continue
    lines="$lines
UUID=$u none msdos rw,noauto  # $l"
done <<EOF
$MARKERS
EOF
block="${block%$END_MARK}${lines}
$END_MARK"

if [ "$APPLY" = "0" ]; then
    echo ""
    echo "Would write to $FSTAB:"
    printf '%s\n' "$block" | grep -avE '^#|^$' | sed 's/^/  /'
    echo ""
    echo "Dry run — re-run with --yes."
    exit 0
fi

sudo touch "$FSTAB"
sudo cp "$FSTAB" "$FSTAB.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
# Replace only our own block; anything else in fstab is left as it is.
existing=$(sudo awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0==b {skip=1} !skip {print} $0==e {skip=0}' "$FSTAB" 2>/dev/null)
printf '%s\n%s\n' "$existing" "$block" | sed '/^$/N;/\n$/D' | sudo tee "$FSTAB" >/dev/null
echo ""
echo "$FSTAB updated:"
sudo grep -av -E '^#|^$' "$FSTAB" | sed 's/^/  /'

echo ""
echo "Unmounting the markers so QEMU can take the disks..."
for whole in $(diskutil list 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external, physical\)/{print $1}'); do
    ser=$(serial_of "$whole")
    echo "$KNOWN" | grep -qw "$ser" || continue
    diskutil unmountDisk "$whole" >/dev/null 2>&1 || true
done
echo "Done — formatted $formatted partition(s). Start the VM normally."
