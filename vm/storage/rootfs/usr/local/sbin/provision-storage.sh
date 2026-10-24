#!/bin/bash
###############################################################################
# provision-storage.sh — usd-role storage provisioner for the Protect VM.
#
# WHY
#
# On a real UNVR, `usd` provisions blank disks automatically at every boot:
# it partitions each disk, builds the swap RAID1 (md0) and the data array
# (md3) at the configured RAID level, makes the filesystems, and mounts the
# recording volume at /volume1. `usd` cannot run on this VM, so nothing did
# that job — a VM with fresh disks just had no /volume1.
#
# This script is the VM's stand-in for that role. It reproduces the exact
# behaviour captured from a real UNVR (see STORAGE-WIRE-CONTRACT.md):
#
#   usable disks  = data disks, blank ones only (see SAFETY below)
#   per disk      : GPT p1 512M / p2 2G / p3 1G / p5 remainder
#   md0  (swap)   : RAID1 over every p2 — all active, no spare
#   md3  (data)   : config RAID level over the p5s; with hotspare, one disk
#                   is held back as a spare ((N-1) active + 1 spare)
#   then          : mkswap md0, mkfs.ext4 md3, mount md3 at /volume1
#
# On a normal reboot the arrays already exist — the script just assembles
# and mounts them. It only ever *creates* arrays from BLANK disks.
#
# SAFETY
#
# Boot-time auto-provisioning is only safe because this script writes to a
# disk solely when that disk is BLANK (no partition table, no filesystem,
# no md superblock). A disk that already carries data — a foreign/imported
# array, a leftover filesystem — is never touched; it is logged and left
# for the operator (`mount-storage.sh import`, or a deliberate wipe). This
# is a deliberate divergence from `usd`, which would reformat unrecognised
# disks under automode; on a VM that could destroy an imported array, so we
# do not. The explicit wipe+reprovision path is `ustorage space nuke`.
#
# CONFIG  (/etc/default/unifi-storage — auto-created with defaults if absent)
#
#   RAID_LEVEL=raid10     raid1 | raid5 | raid6 | raid10
#   HOTSPARE=false        true -> hold one disk back as a hot spare
#   AUTOMODE=false        true -> auto-build an array from blank disks at
#                         boot; false (default) leaves creation to the
#                         web UI ("space nuke"), exactly like a real UNVR
#   FAST_PROVISION=auto   auto | true | false — whether to create the
#                         arrays with mdadm --assume-clean, skipping the
#                         initial RAID resync (a real resync inflates
#                         qcow2-backed disks to full size). auto skips it
#                         only when every data disk is non-rotational
#                         (image-backed). See the knob's note in the
#                         auto-created config below.
#
# INSTALL (inside the VM, as root)
#
#   install -m 0755 provision-storage.sh /usr/local/sbin/provision-storage.sh
#   install -m 0644 provision-storage.service /etc/systemd/system/
#   install -m 0644 provision-storage-retry.service /etc/systemd/system/
#   systemctl daemon-reload && systemctl reenable provision-storage.service
#
# provision-storage.service runs `boot` in usd's slot (after
# local-fs-pre.target, before local-fs.target), i.e. before sysinit.target:
# no network and none of the UniFi stack is running yet. Keep the boot path
# short and limited to what /, /proc, /sys, /dev and /run provide.
#
# USAGE
#
#   provision-storage.sh           # boot logic: assemble, else provision blank
#   provision-storage.sh boot      # same
#   provision-storage.sh provision # force-provision blank disks (no assemble)
#   provision-storage.sh nuke      # erase /volume1 + reprovision (see below)
#   provision-storage.sh retry     # mount an array that starts late (below)
#   provision-storage.sh status    # show what it sees, change nothing
#
# Boot mode starts an array that is assembled but not running because a
# member is missing (degraded), then mounts it. One that cannot start yet
# (too few members) goes to provision-storage-retry.service: `retry` waits
# (bounded) for it to start later, mounts it, and restarts the media
# services that started without it. It never assembles, starts, creates or
# wipes anything. See that unit for why it is a separate unit and not a loop
# here.
#
# `nuke` is the worker behind `ustorage space nuke` (the Storage UI "Erase"
# button): it stops the services using /volume1, tears down and wipes the
# arrays, reprovisions a fresh array, and restarts the services. It is
# DESTRUCTIVE — every recording on /volume1 is erased. Run interactively it
# requires typing ERASE; run from storage-nuke.service it proceeds unattended.
###############################################################################
set -u

STORAGE_VOLUME=/volume1
# The tests (vm/storage/tests/) point this at a scratch file.
CONFIG=${PROVISION_STORAGE_CONFIG:-/etc/default/unifi-storage}
FSTAB=/etc/fstab
MDSTAT=/proc/mdstat
LOCK=/run/provision-storage.lock

# retry: how long to wait for a late array (usd's own 600 s start limit), how
# often to look, and the services to restart once it is mounted.
RETRY_UNIT=provision-storage-retry.service
RETRY_SECS=600
RETRY_EVERY=5
MEDIA_SVCS="ms.service msp.service msr.service mst.service"

log()  { echo "[provision-storage] $*"; }
# warn: for what needs the operator. Under systemd the <3> prefix files the
# line at priority "err" (sd-daemon(3)), so it stands out in journalctl.
# Only when stdout really is the journal stream JOURNAL_STREAM names
# ("dev:ino"): a child that inherited the variable may be writing elsewhere.
TO_JOURNAL=""
[ -n "${JOURNAL_STREAM:-}" ] \
    && [ "$(stat -L -c %d:%i "/proc/$$/fd/1" 2>/dev/null)" = "$JOURNAL_STREAM" ] \
    && TO_JOURNAL=1
warn() {
    if [ -n "$TO_JOURNAL" ]; then
        echo "<3>[provision-storage] $*"
    else
        echo "[provision-storage] WARNING: $*"
    fi
}
die()  { echo "[provision-storage] FATAL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# One run at a time: boot, provision, nuke and each retry attempt hold this
# lock, so a late retry can never scan or mount while a nuke is tearing the
# arrays down, and the reverse. Released on exit.
take_lock() { exec 9>"$LOCK" && flock 9; }
drop_lock() { exec 9>&-; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

###############################################################################
# Config
###############################################################################

if [ ! -f "$CONFIG" ]; then
    log "no $CONFIG — creating with defaults"
    cat > "$CONFIG" <<'EOF'
# Storage provisioning for the Protect VM (provision-storage.sh).
# RAID_LEVEL: raid1 | raid5 | raid6 | raid10  (data array md3)
# HOTSPARE  : true holds one disk back as a hot spare for the data array
# AUTOMODE  : true auto-builds an array from blank disks at boot. false
#             (default) leaves array creation to the user via the web UI,
#             exactly like a real UNVR — boot only assembles/mounts.
# FAST_PROVISION: auto | true | false. Controls the initial RAID resync.
#             A real resync writes every block of every member; against
#             grow-on-write qcow2 storage images that inflates them to
#             full size the instant the array is built, which on a laptop
#             host fills the disk. mdadm --assume-clean skips the resync —
#             safe on a brand-new array: there is no data yet for an
#             inconsistent parity stripe to corrupt, and parity is made
#             correct as data is written.
#               auto  (default) skips the resync ONLY when every data disk
#                     is non-rotational. Image-backed disks present as
#                     SSDs; raw-passthrough spinning disks do not — so real
#                     hardware still gets a faithful resync and only qcow2
#                     images skip it.
#               true  always skips the resync.
#               false always does a full resync (faithful to hardware).
RAID_LEVEL=raid10
HOTSPARE=false
AUTOMODE=false
FAST_PROVISION=auto
EOF
fi
# shellcheck disable=SC1090
. "$CONFIG"
RAID_LEVEL=${RAID_LEVEL:-raid10}
HOTSPARE=${HOTSPARE:-false}
AUTOMODE=${AUTOMODE:-false}
FAST_PROVISION=${FAST_PROVISION:-auto}

# /etc/ustd/storage.conf is written by unifi-core when the operator
# completes the OOBE storage wizard. Its prefer_raid / hotspare are the
# operator's actual choice — authoritative, matching how usd treats
# config.storage on real hardware — so when that file is present they
# override $CONFIG. (RAID_LEVEL may still be overridden by the environment
# above this, but storage.conf reflects what the user picked in the UI.)
USTD_CONF=/etc/ustd/storage.conf
if [ -f "$USTD_CONF" ] && have python3; then
    _ustd=$(python3 - "$USTD_CONF" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print(d.get("prefer_raid") or "", "true" if d.get("hotspare") else "false")
PY
)
    _pr=${_ustd%% *}
    _hs=${_ustd##* }
    if [ -n "$_pr" ]; then
        RAID_LEVEL="$_pr"
        [ -n "$_hs" ] && HOTSPARE="$_hs"
        log "using storage.conf: RAID_LEVEL=$RAID_LEVEL HOTSPARE=$HOTSPARE"
    fi
fi

# mdadm minimum active devices per level. (mdadm permits a 2-device raid10.)
case "$RAID_LEVEL" in
    raid1)  LEVEL_MIN=2; MDLEVEL=1  ;;
    raid10) LEVEL_MIN=2; MDLEVEL=10 ;;
    raid5)  LEVEL_MIN=3; MDLEVEL=5  ;;
    raid6)  LEVEL_MIN=4; MDLEVEL=6  ;;
    *) die "unknown RAID_LEVEL '$RAID_LEVEL' in $CONFIG" ;;
esac

for bin in sgdisk mdadm mkfs.ext4 mkswap blkid; do
    have "$bin" || die "$bin not found"
done

###############################################################################
# Disk discovery
###############################################################################

# basename of the device backing a mountpoint, or '' if not mounted.
mount_src() {
    awk -v m="$1" '$2==m{print $1; exit}' /proc/self/mounts
}

# Parent whole-disk of a partition basename: 'sda5'->'sda', 'nvme0n1p5'->'nvme0n1'.
parent_disk() {
    local n=$1
    if [ -e "/sys/class/block/$n/partition" ]; then
        basename "$(dirname "$(readlink -f "/sys/class/block/$n")")"
    else
        echo "$n"
    fi
}

# The whole disk carrying the OS — never a data disk.
os_disk() {
    local src
    src=$(mount_src /data); [ -n "$src" ] || src=$(mount_src /)
    [ -n "$src" ] && parent_disk "$(basename "$src")"
}

# Nth partition device path for a disk ('sda' -> '/dev/sda5'; nvme -> p5).
part_dev() {
    local disk=$1 num=$2
    case "$disk" in
        nvme*|mmcblk*) echo "/dev/${disk}p${num}" ;;
        *)             echo "/dev/${disk}${num}"  ;;
    esac
}

# True if the running system uses disk $1 directly: the disk or one of its
# partitions is mounted, is active swap, or is named in /etc/fstab by
# UUID/PARTUUID/LABEL or device path. On the VM that is /ssd1 (vdb, whole-disk
# ext4 holding Protect's database). Array members do not count: what is
# mounted or swapped there is the md device, not the disk.
is_system_disk() {
    local disk=$1 d t v
    for d in "/dev/$disk" /dev/"$disk"[0-9]* /dev/"$disk"p[0-9]*; do
        [ -b "$d" ] || continue
        awk -v d="$d" '$1 == d { f = 1 } END { exit !f }' /proc/self/mounts && return 0
        awk -v d="$d" 'NR > 1 && $1 == d { f = 1 } END { exit !f }' /proc/swaps && return 0
        grep -Eq "^[[:space:]]*$d[[:space:]]" "$FSTAB" 2>/dev/null && return 0
        for t in UUID PARTUUID LABEL; do
            v=$(blkid -o value -s "$t" "$d" 2>/dev/null)
            [ -n "$v" ] || continue
            grep -Fq "$t=$v" "$FSTAB" 2>/dev/null && return 0
        done
    done
    return 1
}

# Every present whole data disk (SATA / virtio / NVMe): not the OS disk, and
# not a disk the system uses directly (is_system_disk). The nuke path wipes
# every disk listed here, and provisioning may partition any blank one, so a
# mounted disk such as /ssd1 must never appear.
data_disks() {
    local os n sz
    os=$(os_disk)
    for n in $(ls /sys/block 2>/dev/null | sort); do
        case "$n" in
            sd[a-z]|sd[a-z][a-z]|vd[a-z]|nvme[0-9]*n[0-9]*) ;;
            *) continue ;;
        esac
        [ "$n" = "$os" ] && continue
        is_system_disk "$n" && continue
        sz=$(cat "/sys/block/$n/size" 2>/dev/null || echo 0)
        [ "$sz" -gt 0 ] && echo "$n"
    done
}

# A disk is BLANK when it has no partitions and no filesystem/RAID signature.
is_blank() {
    local disk=$1
    # any partition child in sysfs?
    for p in /sys/block/"$disk"/"$disk"*; do
        [ -e "$p" ] && return 1
    done
    # any signature wipefs/blkid can see (partition table, fs, md member)?
    [ -z "$(blkid -p -o value -s TYPE "/dev/$disk" 2>/dev/null)" ] || return 1
    [ -z "$(blkid -p -o value -s PTTYPE "/dev/$disk" 2>/dev/null)" ] || return 1
    return 0
}

###############################################################################
# Assemble + mount an already-provisioned array
###############################################################################

# Find assembled md arrays: sets DATA_MD (ext4) and SWAP_MD (swap).
scan_arrays() {
    DATA_MD=""; SWAP_MD=""
    local md t
    for md in /dev/md*; do
        [ -b "$md" ] || continue
        t=$(blkid -o value -s TYPE "$md" 2>/dev/null)
        case "$t" in
            ext4)            [ -z "$DATA_MD" ] && DATA_MD=$md ;;
            swap|linux-swap) [ -z "$SWAP_MD" ] && SWAP_MD=$md ;;
        esac
    done
}

# md arrays that are assembled but not running ("inactive" in /proc/mdstat):
# on this VM, an array missing a member that was there when it last ran.
# External-metadata containers (IMSM/DDF; "super external:" on the next line)
# always show as inactive and are left out.
inactive_arrays() {
    awk 'md != "" { if ($0 !~ /super external:/) print "/dev/" md; md = "" }
         $2 == ":" && $3 == "inactive" { md = $1 }
         END { if (md != "") print "/dev/" md }' "$MDSTAT" 2>/dev/null
}

# How many members running array "$1" is missing, by md's own count.
md_degraded() { cat "/sys/block/${1##*/}/md/degraded" 2>/dev/null; }

# Say so, loudly, when the data array runs without all its members.
report_degraded() {
    local n
    n=$(md_degraded "$DATA_MD")
    case "$n" in ''|0|*[!0-9]*) return 0 ;; esac
    warn "data array $DATA_MD is DEGRADED: running with $n member(s) missing"
    warn "  replace the disk; see /proc/mdstat and: mdadm --detail $DATA_MD"
}

# Mount the data array at /volume1, enable swap, migrate + symlink /srv.
mount_arrays() {
    if [ -n "$SWAP_MD" ]; then
        # -p 1: this array is the RAID1 across the USB-attached DAS disks, and
        # paging onto it is the load profile that preceded the June 2026 disk
        # drops. Keep it only as a last-resort cushion, ALWAYS below the
        # NVMe-backed swap on / (pinned pri=100 in /etc/fstab). Without an
        # explicit priority the kernel assigns them by activation order, so the
        # correct ordering would be incidental and could silently invert.
        swapon -p 1 "$SWAP_MD" 2>/dev/null && log "swap on $SWAP_MD (pri 1)" \
            || log "note: swapon $SWAP_MD skipped (already on?)"
    fi
    [ -n "$DATA_MD" ] || { log "no data array found"; return 1; }
    mkdir -p "$STORAGE_VOLUME"
    if mountpoint -q "$STORAGE_VOLUME"; then
        log "$STORAGE_VOLUME already mounted"
    else
        mount "$DATA_MD" "$STORAGE_VOLUME" || die "could not mount $DATA_MD"
        log "mounted $DATA_MD at $STORAGE_VOLUME"
    fi
    mkdir -p "$STORAGE_VOLUME/.srv"
    # Point /srv at the array. Pre-array, the installer leaves /srv as a
    # plain directory on the OS disk and the services populate it there;
    # when the array first appears we migrate that content onto it before
    # replacing /srv with the symlink, so nothing written pre-array is lost.
    if [ -L /srv ]; then
        if [ "$(readlink /srv)" != "$STORAGE_VOLUME/.srv" ]; then
            rm -f /srv && ln -s "$STORAGE_VOLUME/.srv" /srv
            log "/srv -> $STORAGE_VOLUME/.srv"
        fi
    elif [ -d /srv ]; then
        # /srv is the pre-array plain directory the services wrote to on
        # the OS disk. The migration (copy to the array, then swap in the
        # symlink) must not race live services — a running postgres in
        # particular would be left half on vda, half on the array. When
        # this runs at boot the services aren't up yet and the stop loop
        # is a no-op; when it runs live (web-UI array creation) it stops
        # the UniFi stack, migrates, then brings it back — no reboot, no
        # step for the operator to remember.
        local srv_svcs="postgresql unifi-protect unifi-core ds ms msp msr mst uid-agent ulp-go ai-feature-console ai-feature-controller"
        local stopped="" s
        for s in $srv_svcs; do
            if systemctl is-active --quiet "$s" 2>/dev/null; then
                systemctl stop "$s" 2>/dev/null && stopped="$stopped $s"
            fi
        done
        [ -n "${stopped// /}" ] && log "stopped for migration:$stopped"
        if [ -n "$(ls -A /srv 2>/dev/null)" ]; then
            log "migrating /srv contents onto $STORAGE_VOLUME/.srv"
            cp -a /srv/. "$STORAGE_VOLUME/.srv/" || die "migrate /srv failed"
        fi
        rm -rf /srv && ln -s "$STORAGE_VOLUME/.srv" /srv
        log "/srv -> $STORAGE_VOLUME/.srv (migrated)"
        # Protect keeps its postgres cluster on the SSD (vda) via /ssd1
        # detection; nothing to re-bind here after the /srv migration.
        if [ -n "${stopped// /}" ]; then
            log "restarting:$stopped"
            # shellcheck disable=SC2086
            systemctl start $stopped 2>/dev/null
        fi
    else
        ln -s "$STORAGE_VOLUME/.srv" /srv
        log "/srv -> $STORAGE_VOLUME/.srv"
    fi
    return 0
}

###############################################################################
# Fresh provision of blank disks
###############################################################################

# The swap UUID /etc/fstab names for md0, so that a re-provision gives the new
# md0 the same one (mkswap -U) and fstab keeps matching it. Plain mkswap picks
# a random UUID, and after an Erase every boot then waited about 90 s for the
# swap device fstab named, which no longer existed.
#
# fstab_swap_uuid [UUID], where UUID is that of the md swap array about to be
# replaced (empty or absent when there is none), prints:
#   1. UUID, if a swap line in fstab names it: that line is md0's.
#   2. Otherwise the UUID of the one swap line that no present device carries
#      and that has pri=1, the md0 swap line as this project lays fstab out.
#      That is md0's line after its disks were wiped or swapped, including an
#      fstab an older Erase left out of step. pri=1 is required so md0 can
#      never pick up another line's priority (e.g. pri=100, the NVMe swap's).
#   3. Nothing otherwise: several candidates (a warning, no guess), none, or a
#      missing, unreadable or malformed fstab. md0 then gets a new UUID.
# It never edits fstab. Only swap lines whose first field is UUID=<lowercase
# UUID> count: the form blkid prints and systemd looks up in
# /dev/disk/by-uuid. Comments and malformed lines do not match.
fstab_swap_uuid() {
    local re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    local cur="${1:-}" u p seen="" orphans="" others="" n=0
    while read -r u p; do
        [[ $u =~ $re ]] || continue
        if [ -n "$cur" ] && [ "$u" = "$cur" ]; then
            echo "$u"; return 0
        fi
        case "$seen " in *" $u "*) continue ;; esac      # listed twice
        seen="$seen $u"
        blkid -U "$u" >/dev/null 2>&1 && continue          # a present device has it
        if [ "$p" = pri1 ]; then
            orphans="$orphans $u"; n=$((n + 1))
        else
            others="$others $u"
        fi
    done < <(awk '$1 ~ /^UUID=/ && $3 == "swap" {
                     u = substr($1, 6); gsub(/"/, "", u)
                     print u, ($4 ~ /(^|,)pri=1(,|$)/ ? "pri1" : "-") }' "$FSTAB" 2>/dev/null)
    if [ "$n" -eq 1 ]; then
        echo "${orphans# }"
    elif [ "$n" -gt 1 ]; then
        warn "$FSTAB names $n pri=1 swap UUIDs that no disk carries:$orphans" >&2
        warn "  cannot tell which one is md0's, so md0 gets a new UUID; fix $FSTAB by hand" >&2
    elif [ -n "$others" ]; then
        warn "$FSTAB names swap UUID(s) that no disk carries:$others" >&2
        warn "  not given to md0: without pri=1 they would change its swap priority" >&2
    fi
}

# provision "<disks>" "<swap UUID or empty>": the UUID comes from
# fstab_swap_uuid, worked out by the caller before anything is wiped.
provision() {
    local disks="$1" swap_uuid="$2" host n active spare members p2list p5list
    host=$(hostname -s 2>/dev/null || hostname)

    n=$(echo "$disks" | wc -w)
    if [ "$n" -lt 2 ]; then
        log "only $n data disk(s) — need at least 2 to provision; skipping"
        return 1
    fi

    # Spare arithmetic: with HOTSPARE, hold one disk back — but only if the
    # remaining active count still satisfies the RAID level minimum. Below
    # that, fall back to no spare (all disks active).
    if [ "$HOTSPARE" = "true" ] && [ $((n - 1)) -ge "$LEVEL_MIN" ]; then
        active=$((n - 1)); spare=1
    else
        active=$n; spare=0
        [ "$HOTSPARE" = "true" ] && \
            log "hotspare requested but $n disks can't spare one for $RAID_LEVEL — using all active"
    fi
    if [ "$active" -lt "$LEVEL_MIN" ]; then
        die "$RAID_LEVEL needs >= $LEVEL_MIN active disks, have $active"
    fi

    log "provisioning $n disk(s) [$disks] -> md0 RAID1 swap + md3 $RAID_LEVEL ($active active, $spare spare)"

    # 1. Partition every disk: p1 512M / p2 2G / p3 1G / p5 remainder.
    #    p2 and p5 are RAID members (type fd00); p1/p3 mirror the UNVR
    #    layout (reserved, unused).
    for d in $disks; do
        log "partitioning /dev/$d"
        sgdisk --zap-all "/dev/$d" >/dev/null      || die "sgdisk zap /dev/$d failed"
        sgdisk -n1:0:+512M -n2:0:+2G -n3:0:+1G -n5:0:0 \
               -t2:fd00 -t5:fd00 "/dev/$d" >/dev/null || die "sgdisk partition /dev/$d failed"
    done
    have partprobe && partprobe >/dev/null 2>&1
    have udevadm   && udevadm settle
    sleep 1

    # 2. Build the arrays. mdadm --create returns once the array is up; the
    #    initial resync continues in the background (the volume is usable
    #    immediately), so this does not stall boot.
    p2list=""; p5list=""
    for d in $disks; do
        p2list="$p2list $(part_dev "$d" 2)"
        p5list="$p5list $(part_dev "$d" 5)"
    done

    # FAST_PROVISION decides whether to skip the initial resync (see CONFIG
    # note). The array is brand-new here, so --assume-clean corrupts
    # nothing — it just avoids writing every block, which would balloon
    # qcow2-backed disks. In auto mode, skip the resync only when every
    # data disk is non-rotational (image-backed): a raw-passthrough
    # spinning disk reports rotational=1 and still gets a faithful resync.
    local assume_clean="" all_nonrot=true rot
    case "$FAST_PROVISION" in
        true)  assume_clean="--assume-clean" ;;
        false) : ;;
        auto)
            for d in $disks; do
                rot=$(cat "/sys/block/$d/queue/rotational" 2>/dev/null || echo 1)
                [ "$rot" = "0" ] || { all_nonrot=false; break; }
            done
            [ "$all_nonrot" = "true" ] && assume_clean="--assume-clean"
            ;;
        *) die "invalid FAST_PROVISION '$FAST_PROVISION' (auto|true|false)" ;;
    esac
    if [ -n "$assume_clean" ]; then
        log "FAST_PROVISION=$FAST_PROVISION — arrays created with --assume-clean (no resync)"
    else
        log "FAST_PROVISION=$FAST_PROVISION — full RAID resync"
    fi

    log "creating /dev/md0 (RAID1 swap, $n members)"
    # shellcheck disable=SC2086
    mdadm --create /dev/md0 --run --metadata=1.2 --level=1 \
          --raid-devices="$n" --name="$host:0" $assume_clean $p2list >/dev/null 2>&1 \
        || die "mdadm create md0 failed"

    log "creating /dev/md3 ($RAID_LEVEL data, $active active + $spare spare)"
    # shellcheck disable=SC2086
    mdadm --create /dev/md3 --run --metadata=1.2 --level="$MDLEVEL" \
          --raid-devices="$active" --spare-devices="$spare" \
          --name="$host:3" $assume_clean $p5list >/dev/null 2>&1 \
        || die "mdadm create md3 failed"

    # 3. Filesystems. md0 keeps the swap UUID fstab names for it, if any.
    if [ -n "$swap_uuid" ]; then
        log "mkswap /dev/md0 (UUID $swap_uuid, as $FSTAB names it)"
        mkswap -U "$swap_uuid" /dev/md0 >/dev/null 2>&1 || die "mkswap md0 failed"
    else
        log "mkswap /dev/md0 (new UUID; $FSTAB has no md0 swap line to keep, left alone)"
        mkswap /dev/md0 >/dev/null 2>&1 || die "mkswap md0 failed"
    fi
    log "mkfs.ext4 /dev/md3"
    mkfs.ext4 -F -L volume1 /dev/md3 >/dev/null 2>&1 || die "mkfs.ext4 md3 failed"

    DATA_MD=/dev/md3; SWAP_MD=/dev/md0
    mount_arrays
    log "provision complete"
    return 0
}

###############################################################################
# space nuke — teardown + wipe + reprovision (the Storage UI "Erase" action)
###############################################################################

# Services that orchestrate or self-recover — never stopped by a nuke.
NEVER_STOP='unifi-core.service ustated-shim.service provision-storage.service storage-nuke.service provision-storage-retry.service'

# systemd unit owning a PID, via its cgroup. Empty if not a service.
unit_of_pid() {
    [ -r "/proc/$1/cgroup" ] || return 0
    grep -oE '[a-zA-Z0-9@._-]+\.service' "/proc/$1/cgroup" 2>/dev/null | tail -1
}

# Stop every service holding a file open under /volume1; echo the units
# stopped so the caller can restart them. Three rounds, since stopping one
# service can release another's grip.
stop_volume_users() {
    local round pids pid unit units all=""
    for round in 1 2 3; do
        pids=$(fuser -m "$STORAGE_VOLUME" 2>/dev/null | tr -s ' ' '\n' \
               | grep -E '^[0-9]+$' || true)
        [ -z "$pids" ] && break
        units=""
        for pid in $pids; do
            unit=$(unit_of_pid "$pid")
            [ -n "$unit" ] || continue
            case " $NEVER_STOP " in *" $unit "*) continue ;; esac
            units="$units $unit"
        done
        units=$(echo "$units" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
        [ -n "${units// /}" ] || break
        log "stopping volume users:$units"
        # shellcheck disable=SC2086
        systemctl stop $units 2>/dev/null
        all="$all $units"
        sleep 2
    done
    echo "$all" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' '
}

do_nuke() {
    have fuser  || die "fuser not found (psmisc)"
    have wipefs || die "wipefs not found (util-linux)"

    if [ -t 0 ]; then
        printf '%s\n' "space nuke ERASES $STORAGE_VOLUME and every recording on it."
        printf 'Type ERASE to confirm: '
        read -r ans
        [ "$ans" = "ERASE" ] || die "aborted"
    fi
    log "space nuke: tearing down $STORAGE_VOLUME"

    local stopped d p md swap_uuid
    stopped=$(stop_volume_users)

    # Release the volume + swap.
    scan_arrays
    # The new md0 keeps the swap UUID fstab names for the old one. Read it
    # now: the wipe below destroys it.
    swap_uuid=""
    [ -n "$SWAP_MD" ] && swap_uuid=$(blkid -o value -s UUID "$SWAP_MD" 2>/dev/null)
    swap_uuid=$(fstab_swap_uuid "$swap_uuid")
    [ -n "$SWAP_MD" ] && swapoff "$SWAP_MD" 2>/dev/null && log "swapoff $SWAP_MD"
    if mountpoint -q "$STORAGE_VOLUME"; then
        umount "$STORAGE_VOLUME" 2>/dev/null || umount -l "$STORAGE_VOLUME" 2>/dev/null
        log "unmounted $STORAGE_VOLUME"
    fi

    # Stop every md array before touching members — capture 091457 showed
    # uninit fails on members still claimed by an assembled array.
    for md in /dev/md*; do
        [ -b "$md" ] || continue
        mdadm --stop "$md" >/dev/null 2>&1 && log "stopped $md" \
            || log "warning: could not stop $md"
    done

    # Wipe every data disk back to blank: md superblocks, fs signatures, GPT.
    for d in $(data_disks); do
        for p in /sys/block/"$d"/"$d"*; do
            [ -e "$p" ] && mdadm --zero-superblock "/dev/$(basename "$p")" >/dev/null 2>&1
        done
        wipefs -a "/dev/$d" >/dev/null 2>&1
        sgdisk --zap-all "/dev/$d" >/dev/null 2>&1
        log "wiped /dev/$d"
    done
    have partprobe && partprobe >/dev/null 2>&1
    have udevadm   && udevadm settle
    sleep 1

    # Reprovision from the now-blank disks.
    local blank=""
    for d in $(data_disks); do is_blank "$d" && blank="$blank $d"; done
    [ -n "${blank// /}" ] || die "no blank disks after wipe — aborting"
    provision "${blank# }" "$swap_uuid" || die "reprovision failed"

    # Restart the services we stopped — they come up against the fresh volume.
    if [ -n "${stopped// /}" ]; then
        log "restarting:$stopped"
        # shellcheck disable=SC2086
        systemctl start $stopped 2>/dev/null
    fi
    log "space nuke complete"
}

###############################################################################
# Actions
###############################################################################

do_status() {
    log "config: RAID_LEVEL=$RAID_LEVEL HOTSPARE=$HOTSPARE AUTOMODE=$AUTOMODE"
    log "        FAST_PROVISION=$FAST_PROVISION"
    log "OS disk (preserved): $(os_disk)"
    local disks; disks=$(data_disks | tr '\n' ' ')
    log "data disks: ${disks:-<none>}"
    for d in $disks; do
        if is_blank "$d"; then log "  /dev/$d — BLANK"; else log "  /dev/$d — has data"; fi
    done
    mdadm --assemble --scan >/dev/null 2>&1 || true
    scan_arrays
    log "data array:  ${DATA_MD:-<none>}"
    log "swap array:  ${SWAP_MD:-<none>}"
    mountpoint -q "$STORAGE_VOLUME" && log "$STORAGE_VOLUME: mounted" \
        || log "$STORAGE_VOLUME: not mounted"
}

do_boot() {
    if mountpoint -q "$STORAGE_VOLUME"; then
        log "$STORAGE_VOLUME already mounted — nothing to do"
        exit 0
    fi

    # 1. Existing arrays take priority — never re-provision over them.
    mdadm --assemble --scan >/dev/null 2>&1 || true
    sleep 1

    # 1a. Arrays assembled but not running, i.e. short a member. The
    #     initramfs assembles arrays incrementally and leaves such an array
    #     inactive. The assemble above then finds every member busy, and
    #     udev's re-run of `mdadm --incremental` after the switch to the real
    #     root fails the same way, so mdadm-last-resort@ is never armed for
    #     it (mdadm 4.2 Assemble.c and Incremental.c). Nothing else would
    #     ever start it. Start it degraded, as usd does on a UNVR and as the
    #     assemble above would have if the initramfs had not claimed the
    #     members first. `mdadm --run` only starts an existing array, and md
    #     refuses unless its level has enough members; nothing is created,
    #     added or wiped. Read before the scan below, so an array that starts
    #     in between is found by the scan.
    local pending md
    pending=$(inactive_arrays | tr '\n' ' ')
    for md in $pending; do
        if mdadm --run "$md" >/dev/null 2>&1; then
            warn "$md was assembled but not running (a member is missing): started it DEGRADED"
        else
            warn "$md is assembled but cannot start: too few members"
        fi
    done
    scan_arrays
    if [ -n "$DATA_MD" ]; then
        log "existing data array $DATA_MD — assembling and mounting"
        report_degraded
        mount_arrays && exit 0
        die "failed to mount existing array $DATA_MD"
    fi

    # 1b. Still no data array, but there was one that could not start (too
    #     few members): it may start later, when a member comes back (mdadm's
    #     own incremental assembly or mdadm-last-resort@ then starts it) or by
    #     hand. Hand it to the retry unit, which mounts it then; waiting here
    #     would hold networking and ssh. --no-block: that unit orders after
    #     sysinit.target, which waits for this one. Never provision past such
    #     an array: blank disks here may be its replacement members.
    if [ -n "${pending// /}" ]; then
        warn "no data array is running; not touching any disk (assembled, not running: ${pending% })"
        if systemctl --no-block start "$RETRY_UNIT" 2>/dev/null; then
            warn "  $RETRY_UNIT mounts the data array once it runs (waits up to ${RETRY_SECS}s)"
        else
            warn "  could not start $RETRY_UNIT; once the array runs: $0 retry"
        fi
        exit 0
    fi

    # 2. No array. Look at the data disks.
    local disks blank nonblank
    disks=$(data_disks | tr '\n' ' ')
    [ -n "${disks// /}" ] || { log "no data disks present — nothing to provision"; exit 0; }

    blank=""; nonblank=""
    for d in $disks; do
        if is_blank "$d"; then blank="$blank $d"; else nonblank="$nonblank $d"; fi
    done

    if [ -n "${nonblank// /}" ]; then
        log "disks with existing data (NOT touched):$nonblank"
        log "  -> import with mount-storage.sh, or wipe deliberately to provision"
    fi
    [ -n "${blank// /}" ] || { log "no blank disks to provision"; exit 0; }

    if [ "$AUTOMODE" != "true" ]; then
        log "AUTOMODE=false — blank disks present but auto-provision disabled"
        exit 0
    fi

    provision "${blank# }" "$(fstab_swap_uuid)"
}

# ms, msp, msr and mst look at /srv once, when they start. Started before the
# array was mounted, msr marks the recording path non-operational and records
# nothing, msp never starts playback, ms and mst log to the local fallback,
# each until restarted (see their 10-wait-for-volume1.conf drop-ins, which
# cannot order them after a mount that is not in fstab). Restart those that
# are up or starting, and those that failed (perhaps for want of /srv; the
# reset-failed clears a start limit). One that is stopped, or not started
# yet, sees the volume when it starts.
restart_media_services() {
    local s units=""
    for s in $MEDIA_SVCS; do
        case "$(systemctl is-active "$s" 2>/dev/null)" in
            active|activating|reloading|failed) units="$units $s" ;;
        esac
    done
    if [ -z "$units" ]; then
        log "no media service is running yet; nothing to restart"
        return 0
    fi
    log "restarting, they started without $STORAGE_VOLUME:$units"
    # shellcheck disable=SC2086
    systemctl reset-failed $units 2>/dev/null
    # shellcheck disable=SC2086
    systemctl --no-block restart $units || warn "restart failed:$units"
}

# retry: for an array boot mode found assembled but could not start (see step
# 1b of do_boot). Look every RETRY_EVERY s, for up to RETRY_SECS, for a running
# data array; mount it and restart the media services. Only ever mounts an
# array that is already running: never assembles, starts, creates or wipes
# one. Safe to run by hand.
do_retry() {
    local waited=0
    log "waiting up to ${RETRY_SECS}s for the data array to run"
    while :; do
        take_lock || die "cannot take $LOCK"
        if mountpoint -q "$STORAGE_VOLUME"; then
            log "$STORAGE_VOLUME is mounted now - nothing to do"
            exit 0
        fi
        scan_arrays
        if [ -n "$DATA_MD" ]; then
            warn "data array $DATA_MD is running now; mounting it late, after Protect started"
            report_degraded
            mount_arrays
            restart_media_services
            exit 0
        fi
        drop_lock
        [ "$waited" -lt "$RETRY_SECS" ] || break
        sleep "$RETRY_EVERY"
        waited=$((waited + RETRY_EVERY))
    done
    warn "gave up after ${RETRY_SECS}s: no data array is running, so $STORAGE_VOLUME is NOT mounted and Protect records nothing"
    warn "  assembled but not running: $(inactive_arrays | tr '\n' ' ')(see /proc/mdstat)"
    warn "  once the array runs: $0 retry"
    exit 1
}

main() {
    local disks d
    case "${1:-boot}" in
        boot)
            take_lock || warn "cannot take $LOCK; carrying on without it"
            do_boot ;;
        provision)
            # Force-provision blank disks without the assemble step. Used by
            # the `ustorage space nuke` reprovision path.
            take_lock || die "cannot take $LOCK"
            disks=""
            for d in $(data_disks); do is_blank "$d" && disks="$disks $d"; done
            [ -n "${disks// /}" ] || die "no blank disks to provision"
            provision "${disks# }" "$(fstab_swap_uuid)"
            ;;
        nuke)      take_lock || die "cannot take $LOCK"; do_nuke ;;
        retry)     do_retry ;;
        status)    do_status ;;
        *) echo "usage: $0 [boot|provision|nuke|retry|status]" >&2; exit 1 ;;
    esac
}

# Sourced (the tests in vm/storage/tests/ do that): define, do not run.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
main "$@"
