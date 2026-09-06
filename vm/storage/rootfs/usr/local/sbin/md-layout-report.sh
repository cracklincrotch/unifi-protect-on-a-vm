#!/bin/bash
###############################################################################
# md-layout-report.sh — push the md member map to the QEMU host.
#
# Emits one line per array member:
#     <array> <level> <layout> <raid_disks> <role> <serial> <state>
# e.g.  md3 raid10 258 4 2 8HKEXN1H in_sync
# (raid10 layout 258 = 0x102 = near-2. The serial is QEMU's, visible in the
# guest because the launcher sets serial= on every scsi-hd.)
#
# The host's DAS fault handler uses this to decide, PER RAID LEVEL, whether a
# failed disk can be hot-detached so the guest keeps recording degraded:
# raid1 needs one survivor, raid5 tolerates no prior loss, raid6 one,
# raid10/near-2 needs the role^1 partner alive, raid0 never. The guest is
# paused and unaskable when that decision is made, so the map must already be
# on the host — a systemd timer sends it every 5 minutes.
###############################################################################
set -u
report() {
    local md name level layout nd d member role state parent serial
    for md in /sys/block/md*; do
        [ -d "$md/md" ] || continue
        name=$(basename "$md")
        level=$(cat "$md/md/level" 2>/dev/null || echo '?')
        layout=$(cat "$md/md/layout" 2>/dev/null || echo 0)
        nd=$(cat "$md/md/raid_disks" 2>/dev/null || echo 0)
        for d in "$md"/md/dev-*; do
            [ -d "$d" ] || continue
            member=$(basename "$d"); member=${member#dev-}
            role=$(cat "$d/slot" 2>/dev/null || echo '?')
            state=$(cat "$d/state" 2>/dev/null | tr ' ' ',' )
            parent=$(lsblk -no PKNAME "/dev/$member" 2>/dev/null | head -1)
            serial=$(lsblk -dno SERIAL "/dev/${parent:-$member}" 2>/dev/null | tr -d '[:space:]')
            echo "$name $level $layout $nd $role ${serial:-?} ${state:-?}"
        done
    done
}
payload="$(report)"
[ -n "$payload" ] || exit 0
exec /usr/local/bin/protect-on-mac-ctl store md-layout \
    "$(printf '%s\n' "$payload" | base64 -w0)"
