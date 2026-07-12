#!/bin/bash
###############################################################################
# unifi-core-storage-patch.sh
#
# Re-applies BOTH storage patches to unifi-core's bundled service.js on every
# boot. service.js is a vendor bundle — a unifi-core update (e.g. --sync-os)
# overwrites it and reverts the patches, so this runs at boot to restore them.
#
#   Patch A (disk LIST): system.ustorage.inspect hardcodes `disks:[]` and only
#     calls `ustorage space inspect`. Patch A makes it also call
#     `ustorage disk inspect` (served by ustorage-vm.py) so the Storage panel's
#     disk list populates.
#   Patch B (drive DETECTION): a `return <fn>()?s.push(...)` site gates whether
#     drives get pushed into the detected set; Patch B forces it to always push
#     (`return <fn>(),!0?s.push`). Previously this lived only in the installer
#     and self-healed nowhere — folded in here so it survives updates too.
#
# Both are idempotent and boot-safe: normal state (already applied, or cleanly
# applied now) exits 0 quietly. BUT if a patch's anchor/pattern is MISSING —
# not applied AND the site to patch can't be found — that usually means a
# unifi-core update renamed the minified identifiers, which silently breaks the
# Storage panel. So that case ALERTS loudly (journal err + Pushover) instead of
# a silent no-op: the signal to re-derive the anchor for the new bundle.
###############################################################################
set -u

SVC=/usr/share/unifi-core/app/service.js

# Patch A — disk LIST
A_MARKER='["disk","inspect"]'
A_ANCHOR='t={space:c,disks:[],sdcards:[]};'
A_REPL='let dd=[];try{dd=JSON.parse((await J("ustorage",["disk","inspect"])).stdout);}catch(_){va.error("Failed to retrieve disk info via ustorage:",_);}t={space:c,disks:dd,sdcards:[]};'

# Patch B — drive DETECTION
B_MARKER=',!0?s.push'          # present once Patch B is applied
B_UNPATCHED='()?s.push'        # the un-patched site: `return <fn>()?s.push`
B_SED='s/\(return [A-Za-z_$][A-Za-z0-9_$]*()\)?s\.push/\1,!0?s.push/'

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

# ---- Patch A (disk LIST) ----
if grep -qF "$A_MARKER" "$SVC"; then
    echo "storage-patch: Patch A already applied"
else
    a_n=$(grep -oF "$A_ANCHOR" "$SVC" 2>/dev/null | wc -l)
    if [ "$a_n" = "1" ]; then
        python3 - "$SVC" "$A_ANCHOR" "$A_REPL" <<'PY'
import sys
path, anchor, repl = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
open(path + ".prepatch", "w").write(s)
open(path, "w").write(s.replace(anchor, repl, 1))
print("storage-patch: Patch A applied (original saved to %s.prepatch)" % path)
PY
    else
        alert "Patch A anchor not found (count=$a_n) in service.js — the Storage disk LIST will be empty. Re-derive the anchor for this unifi-core version."
    fi
fi

# ---- Patch B (drive DETECTION) ----
if grep -qF "$B_MARKER" "$SVC"; then
    echo "storage-patch: Patch B already applied"
elif grep -qF "$B_UNPATCHED" "$SVC"; then
    sed -i "$B_SED" "$SVC"
    if grep -qF "$B_MARKER" "$SVC"; then
        echo "storage-patch: Patch B applied"
    else
        alert "Patch B substitution did not take (site present but sed failed) — drive DETECTION may be broken."
    fi
else
    alert "Patch B site ('return <fn>()?s.push') not found in service.js — drive DETECTION patch could not be applied. Re-derive it for this unifi-core version."
fi

exit 0
