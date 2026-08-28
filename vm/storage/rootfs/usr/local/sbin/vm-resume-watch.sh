#!/bin/bash
###############################################################################
# vm-resume-watch.sh — detect that this VM was PAUSED, and recover.
#
# A paused guest cannot see time pass: QEMU freezes the vCPU, so the system
# clock and CLOCK_MONOTONIC stop together and resume looks seamless from the
# inside. The emulated RTC does NOT stop -- QEMU's default is clock=host -- so
# after a pause the RTC leads the system clock by exactly the pause duration.
# That difference is the only in-guest evidence a pause occurred.
#
# Threshold is 30s because that is where Protect's own timeouts start firing
# (ds ping/pong dies ~25s, grpc 10s, db idle 30s). Under that, everything
# self-heals and a restart would cost more than it saves. Over it, a 90s
# restart is cheap next to the silent half-recovery it prevents.
#
# OBSERVE=1 (the default until proven) logs what it WOULD do and changes
# nothing -- we have not yet watched the RTC advance through a real pause.
###############################################################################
set -u
CONF=/etc/default/vm-resume-watch
THRESHOLD=30
INTERVAL=15
OBSERVE=1
[ -r "$CONF" ] && . "$CONF"
LOG=/var/log/vm-resume-watch.log
STATE=/run/vm-resume-watch.state
say() { echo "$(date '+%F %T') $*" >> "$LOG"; }

say "started (threshold=${THRESHOLD}s interval=${INTERVAL}s observe=${OBSERVE})"
while true; do
    sleep "$INTERVAL"
    sys=$(date +%s)
    rtc_str=$(hwclock --show 2>/dev/null) || { say "hwclock unreadable"; continue; }
    rtc=$(date -d "$rtc_str" +%s 2>/dev/null) || continue
    gap=$(( rtc - sys ))
    echo "$(date '+%F %T') gap=${gap}s" > "$STATE"
    # only a POSITIVE gap means the guest lost time (RTC ran on while we froze)
    if [ "$gap" -ge "$THRESHOLD" ]; then
        say "PAUSE DETECTED: RTC leads system clock by ${gap}s"
        if [ "$OBSERVE" = "1" ]; then
            say "observe-only: would step clock and run vm-resume-recover.sh ${gap}"
            # resync anyway so we do not re-fire on the same gap forever
            hwclock --hctosys 2>/dev/null && say "observe-only: clock stepped (safe, no restart)"
        else
            hwclock --hctosys 2>/dev/null && say "clock stepped from RTC"
            /usr/local/sbin/vm-resume-recover.sh "$gap" >> "$LOG" 2>&1 &
        fi
    fi
done
