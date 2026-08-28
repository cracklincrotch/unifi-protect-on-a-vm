#!/bin/bash
###############################################################################
# vm-resume-recover.sh — bring Protect back cleanly after the VM was PAUSED.
#
# QEMU pauses this guest on a DAS I/O error (werror=stop). While paused the
# vCPU is frozen, so the guest cannot tell time passed -- but the emulated RTC
# keeps host time (QEMU default clock=host), so on resume the system clock is
# stale by exactly the pause duration. That gap is our only evidence a pause
# happened, and it is what triggers this.
#
# Why restart at all: after >30s Protect's own timeouts have fired -- ds
# ping/pong dies at ~25s, its websocket_client gives up after ~50s, and its
# reconnect blacklist (5 attempts / 60s block) meets 42 cameras reconnecting at
# once. That combination is how you get the SILENT half-recovery seen on
# 2026-08-26, where every unit reported "active" and nothing was written for
# 3h34m. A predictable 90s restart beats an open-ended silent failure.
#
# Order is load-bearing: ms and msr MUST restart together. Restarting ms alone
# leaves the recorder holding stale state and it logs
# "BaseOutStream::UnLink ... _pInStream is NULL" while recording nothing.
###############################################################################
set -u
LOG=/var/log/vm-resume-recover.log
CONF=/usr/local/etc/md-health-watch.conf     # reuse the existing Pushover creds
say() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

notify() {   # notify <title> <message> [priority]
    [ -r "$CONF" ] || return 0
    local tok usr
    tok=$(grep -aoE '^PUSHOVER_TOKEN=.*' "$CONF" | cut -d= -f2- | tr -d '"'"'"' ')
    usr=$(grep -aoE '^PUSHOVER_USER=.*'  "$CONF" | cut -d= -f2- | tr -d '"'"'"' ')
    [ -n "$tok" ] && [ -n "$usr" ] || return 0
    curl -sS -m 10 -F "token=$tok" -F "user=$usr" \
         -F "title=$1" -F "message=$2" -F "priority=${3:-0}" \
         https://api.pushover.net/1/messages.json >/dev/null 2>&1 || true
}

GAP="${1:-unknown}"
say "=== resume recovery starting (clock gap ${GAP}s) ==="

# 1. The accessory API must be served or Protect 7.2 blocks on the peripheral
#    state stream and records NOTHING no matter how often we restart it.
if ! grep -q "AccessoryAPIService" /usr/local/bin/ustated-shim.js 2>/dev/null; then
    say "FATAL: ustated-shim.js has no accessory API -- recording cannot resume"
    notify "UNVR recovery FAILED" "ustated-shim lost its accessory API patch; Protect 7.2 will not record until it is restored." 1
    exit 2
fi
systemctl is-active --quiet ustated-shim || systemctl restart ustated-shim

# 2. Media stack, in the only order that works.
say "stopping unifi-protect"
systemctl stop unifi-protect
sleep 3
for u in ds mst msp msr ms; do
    say "restarting $u"
    systemctl restart "$u"
    sleep 3
done
sleep 15
say "starting unifi-protect"
systemctl start unifi-protect

# 3. VERIFY. "active" means nothing -- on 08-26 every unit was active while
#    the array took zero writes. Recording is proven by bytes on disk.
ok=0
for i in $(seq 1 12); do
    sleep 15
    a=$(awk '$3=="md3"{print $10}' /proc/diskstats)
    sleep 10
    b=$(awk '$3=="md3"{print $10}' /proc/diskstats)
    mbs=$(( (b-a)*512/10/1024/1024 ))
    n=$(find /volume1/.srv/unifi-protect/video -name '*.ubv' -newermt '-2 minutes' 2>/dev/null | wc -l)
    say "verify pass $i: md3 ${mbs} MB/s, ${n} .ubv touched in 2 min"
    if [ "$mbs" -ge 5 ] && [ "$n" -ge 5 ]; then ok=1; break; fi
done

if [ "$ok" = 1 ]; then
    say "=== recovery OK: recording confirmed ==="
    notify "UNVR recovered" "VM was paused ${GAP}s. Clock stepped, media stack restarted, recording confirmed at ${mbs} MB/s."
else
    say "=== recovery FAILED: no recording after restart ==="
    notify "UNVR recovery FAILED" "VM paused ${GAP}s. Stack restarted but NOTHING is recording after 5 minutes. Needs hands." 1
    exit 1
fi
