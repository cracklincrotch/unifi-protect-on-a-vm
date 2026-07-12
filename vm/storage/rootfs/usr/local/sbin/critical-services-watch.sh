#!/bin/sh
# critical-services-watch.sh — Pushover alert when a long-running service or
# postgres cluster that should ALWAYS be up is failed/inactive, or a cluster is
# up but not accepting connections. Catches silent degradation — e.g. the
# access syslog engine (postgresql@14-access) that failed unnoticed for months
# because the surface signals (doors working, service "active") looked fine.
#
# Runs from a systemd timer (~5 min). Alerts on STATE CHANGE only (no spam) and
# on recovery. Reuses the md-health-watch Pushover credentials.
#
# ONLY monitors units that must always be active on this VM. Intentionally
# excludes: ai-feature-controller (ExecCondition-gated on AI-accelerator
# hardware absent on a VM), uid-agent (UniFi Identity, kept dormant here), and
# all oneshot units (seed-anonid, provision-storage, unifi-core-storage-patch,
# the postgresql.service umbrella).

CONF=/usr/local/etc/md-health-watch.conf
STATE=/run/critical-services-watch.state
HEARTBEAT=/run/critical-services-watch.heartbeat
HOST=$(hostname 2>/dev/null || echo unvr)

[ -r "$CONF" ] && . "$CONF"
date '+%s' > "$HEARTBEAT" 2>/dev/null

UNITS="unifi-core unifi-protect ds ai-feature-console ulp-go unifi-access ustated-shim postgresql@14-main postgresql@14-protect postgresql@14-access"

# "unit:port" pairs to also probe with pg_isready (up but not accepting = bad).
DBPROBES="postgresql@14-main:5432 postgresql@14-protect:5433 postgresql@14-access:5435"

bad=""
for u in $UNITS; do
    st=$(systemctl is-active "$u" 2>/dev/null)
    [ "$st" = active ] || bad="$bad
  $u: $st"
done
for p in $DBPROBES; do
    unit=${p%:*}; port=${p#*:}
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        pg_isready -q -p "$port" 2>/dev/null || bad="$bad
  $unit: active but not accepting on :$port"
    fi
done

if [ -z "$bad" ]; then
    cur="OK"
else
    cur="BAD:$(printf '%s' "$bad" | md5sum | cut -d' ' -f1)"
fi
prev=$(cat "$STATE" 2>/dev/null)
printf '%s\n' "$cur" > "$STATE"

# Unchanged -> nothing to do. First run that is already OK -> just record.
[ "$cur" = "$prev" ] && exit 0
[ -z "$prev" ] && [ -z "$bad" ] && exit 0

if [ -z "$bad" ]; then
    TITLE="UNVR services RECOVERED"; PRIO=0
    MSG="All monitored services/DBs are healthy again on $HOST."
else
    TITLE="UNVR service DOWN"; PRIO=1
    MSG="$HOST — a critical service or DB cluster is not running:$bad

Monitored: $UNITS"
fi

if [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then
    /usr/bin/curl -s --max-time 20 \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "title=$TITLE" \
        --form-string "priority=$PRIO" \
        --form-string "message=$MSG" \
        https://api.pushover.net/1/messages.json >/dev/null 2>&1
fi
exit 0
