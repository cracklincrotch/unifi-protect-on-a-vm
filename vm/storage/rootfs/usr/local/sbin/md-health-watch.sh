#!/bin/sh
# md-health-watch.sh — Pushover alert when any md array loses redundancy.
# Runs from a systemd timer (~60s). Alerts on STATE CHANGE only (no spam):
# healthy->degraded, a worse failure, array gone, and degraded->recovered.
# Keys off the [UU__] map: a '_' = a slot with no working member = redundancy
# lost (covers failed members AND rebuild-in-progress). A plain resync with
# all members present ([UUUU]) is NOT flagged.

CONF=/usr/local/etc/md-health-watch.conf
STATE=/run/md-health-watch.state
HEARTBEAT=/run/md-health-watch.heartbeat
HOST=$(hostname 2>/dev/null || echo unvr)

[ -r "$CONF" ] && . "$CONF"
date '+%s' > "$HEARTBEAT" 2>/dev/null

mdstat=$(cat /proc/mdstat 2>/dev/null)
arrays=$(printf '%s\n' "$mdstat" | grep -oE '^md[0-9]+')

bad=""
sev=0   # 0=ok  1=degraded(lost redundancy)  2=inactive/failed/missing

for md in $arrays; do
    blk=$(printf '%s\n' "$mdstat" | grep -A1 "^$md :")
    hdr=$(printf '%s\n' "$blk" | head -1)
    stat=$(printf '%s\n' "$blk" | sed -n 2p)
    if printf '%s\n' "$hdr" | grep -q "inactive"; then
        bad="$bad
$md: INACTIVE — $hdr"
        sev=2; continue
    fi
    map=$(printf '%s\n' "$stat" | grep -oE '\[[U_]+\]' | tail -1)
    if [ -n "$map" ] && printf '%s\n' "$map" | grep -q '_'; then
        bad="$bad
$md: DEGRADED $map — $(printf '%s\n' "$hdr" | sed 's/ : active / /')"
        [ "$sev" -lt 1 ] && sev=1
    fi
done

# md3 is the recording array — its disappearance is catastrophic.
if ! printf '%s\n' "$arrays" | grep -qx "md3"; then
    bad="$bad
md3: MISSING from /proc/mdstat (array gone)"
    sev=2
fi

if [ "$sev" -eq 0 ]; then
    cur="OK"
else
    cur="BAD:$sev:$(printf '%s' "$bad" | md5sum | cut -d' ' -f1)"
fi
prev=$(cat "$STATE" 2>/dev/null)
printf '%s\n' "$cur" > "$STATE"

# No change -> nothing to do. First run that is already OK -> just record.
[ "$cur" = "$prev" ] && exit 0
[ -z "$prev" ] && [ "$sev" -eq 0 ] && exit 0

if [ "$sev" -eq 0 ]; then
    TITLE="UNVR array RECOVERED"; PRIO=0; EXTRA=""
    MSG="All md arrays healthy on $HOST.
$(printf '%s\n' "$mdstat" | grep -A1 '^md3')"
elif [ "$sev" -ge 2 ]; then
    TITLE="UNVR ARRAY FAILED/MISSING"; PRIO=2
    EXTRA="--form-string retry=120 --form-string expire=3600"
    MSG="$HOST — CRITICAL array fault:$bad

$(printf '%s\n' "$mdstat" | grep -A1 '^md')"
else
    TITLE="UNVR array DEGRADED"; PRIO=1; EXTRA=""
    MSG="$HOST — array lost a member (redundancy reduced):$bad

$(printf '%s\n' "$mdstat" | grep -A1 '^md')"
fi

if [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then
    /usr/bin/curl -s --max-time 20 \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "title=$TITLE" \
        --form-string "priority=$PRIO" \
        $EXTRA \
        --form-string "message=$MSG" \
        https://api.pushover.net/1/messages.json >/dev/null 2>&1
fi
exit 0
