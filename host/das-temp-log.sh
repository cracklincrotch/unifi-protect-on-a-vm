#!/bin/bash
###############################################################################
# das-temp-log.sh — one CSV row per DAS drive per run: epoch,serial,tempC.
#
# The DAS bridge chips are the prime suspect for the recurring USB bus faults,
# and the recent ones all landed during multi-day resyncs -- sustained I/O,
# maximum heat. Drive SMART temperature is the closest readable proxy for
# enclosure internals, so log it continuously: a baseline before the heatsink
# retrofit (2026-08-27), the delta after it, and a temperature trace to line
# up against the timestamp of every future fault in vm-io-events.log.
#
# Run by launchd every 5 minutes (com.protect-on-mac.das-temps). Reads the
# serials from disk-serial.map but resolves nodes fresh each run -- the map's
# nodes go stale whenever the bus re-enumerates.
###############################################################################
set -u
MAP="${DISK_MAP:-$(dirname "$0")/../vm-data/disk-serial.map}"
OUT="${DAS_TEMP_CSV:-$(dirname "$0")/../vm-data/das-temps.csv}"
SMART=/opt/homebrew/bin/smartctl
[ -r "$MAP" ] || exit 0
now=$(date +%s)
for dev in $(diskutil list 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external, physical\)/{print $1}'); do
    j=$("$SMART" -j -a "$dev" 2>/dev/null) || continue
    line=$(printf '%s' "$j" | /usr/bin/python3 -c '
import sys, json
d = json.load(sys.stdin)
s = d.get("serial_number") or ""
t = (d.get("temperature") or {}).get("current")
print("%s %s" % (s, t if t is not None else ""))' 2>/dev/null)
    ser=${line%% *}; temp=${line#* }
    [ -n "$ser" ] && grep -q "^$ser	" "$MAP" || continue
    [ -n "$temp" ] && echo "$now,$ser,$temp" >> "$OUT"
done
