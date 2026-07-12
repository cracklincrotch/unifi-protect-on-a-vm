#!/bin/bash
###############################################################################
# unifi-core-storage-patch.sh
#
# Re-applies the storage disk-list patch to unifi-core's bundled service.js on
# every boot. service.js is a vendor bundle — a unifi-core update (e.g.
# --sync-os) overwrites it and reverts the patch, so this restores it.
#
#   Patch A (disk LIST): unifi-core's storage-inspect handler builds its
#     snapshot as `tee={space:e,disks:[],sdcards:[]}` — disks hardcoded empty,
#     populated only from `ustorage space inspect`. The patch injects a
#     `ustorage disk inspect` call (served by ustorage-vm.py) so the Storage
#     panel's per-disk list populates. tG() returns this `tee`, and on the v2
#     path Lf() returns tG(), so the patched disks reach the UI.
#
# The anchor + minified var names are compiler-assigned and CHANGE with each
# unifi-core version. This anchor targets the 5.1.117-era bundle (unifi-core
# 5.1.x / UniFi OS 5.1.19). If a future version renames the identifiers the
# anchor won't match — that is NOT ignored silently: it ALERTS (journal err +
# Pushover) so the anchor gets re-derived.
#
# HISTORY: the 5.1.110-era bundle used anchor `t={space:c,disks:[],sdcards:[]}`
# plus a separate "Patch B" drive-detection gate (`return <fn>()?s.push`, forced
# to always-push). 5.1.117 refactored the storage handler (new anchor below) and
# removed that gate entirely — disks now flow solely via `ustorage disk inspect`
# — so Patch B is obsolete and no longer applied.
#
# Idempotent + boot-safe: already-applied, or cleanly-applied-now, exits 0.
###############################################################################
set -u

SVC=/usr/share/unifi-core/app/service.js

# Patch A — disk LIST (5.1.117-era anchor)
MARKER='["disk","inspect"]'
ANCHOR='tee={space:e,disks:[],sdcards:[]};'
REPL='let dd=[];try{dd=JSON.parse((await Q("ustorage",["disk","inspect"])).stdout);}catch(_){hHe.error("Failed to retrieve disk info via ustorage:",_);}tee={space:e,disks:dd,sdcards:[]};'

PUSH_CONF=/usr/local/etc/md-health-watch.conf

alert() {
    local msg="$1"
    echo "storage-patch: ALERT: $msg" >&2
    logger -t unifi-core-storage-patch -p daemon.err "ALERT: $msg" 2>/dev/null || true
    if [ -r "$PUSH_CONF" ]; then
        # shellcheck disable=SC1090
        . "$PUSH_CONF" 2>/dev/null || true
        if [ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER:-}" ]; then
            /usr/bin/curl -s --max-time 20 \
                --form-string "token=$PUSHOVER_TOKEN" \
                --form-string "user=$PUSHOVER_USER" \
                --form-string "title=Pinecrest-UNVR storage-patch" \
                --form-string "priority=1" \
                --form-string "message=$msg" \
                https://api.pushover.net/1/messages.json >/dev/null 2>&1 || true
        fi
    fi
}

if [ ! -f "$SVC" ]; then
    echo "storage-patch: $SVC not found — skipping"
    exit 0
fi

if grep -qF "$MARKER" "$SVC"; then
    echo "storage-patch: already applied"
    exit 0
fi

n=$(grep -oF "$ANCHOR" "$SVC" 2>/dev/null | wc -l)
if [ "$n" != "1" ]; then
    alert "Patch A anchor not found (count=$n) in service.js — the Storage disk LIST will be empty. A unifi-core update likely renamed the minified identifiers; re-derive the anchor for this version."
    exit 0
fi

python3 - "$SVC" "$ANCHOR" "$REPL" <<'PY'
import sys
path, anchor, repl = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if s.count(anchor) != 1:
    sys.stderr.write("storage-patch: anchor count changed mid-run — NOT patching\n")
    sys.exit(0)
open(path + ".prepatch", "w").write(s)
open(path, "w").write(s.replace(anchor, repl, 1))
print("storage-patch: Patch A applied (original saved to %s.prepatch)" % path)
PY
exit 0
