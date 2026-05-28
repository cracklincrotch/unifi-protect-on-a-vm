#!/bin/bash
###############################################################################
# provision-on-setup.sh — first-time storage provisioning trigger.
#
# On a real UNVR, `usd` watches /etc/ustd/storage.conf and builds the array
# the moment the operator finishes the OOBE storage wizard: unifi-core
# writes "setup": true into that file (plus prefer_raid / hotspare), and
# usd provisions. `usd` cannot run on this VM, so provision-on-setup.path
# watches the same file and runs this script instead — standing in for
# exactly that piece of usd.
#
# It provisions ONCE. The persistent marker /etc/ustd/has_setup_storage —
# the same flag usd writes after a successful provision — gates it, so a
# later edit of storage.conf, or a reboot, never re-triggers a build.
# Reconfiguring storage afterwards goes through the Erase path
# (`ustorage space nuke` -> storage-nuke.service), exactly as on hardware.
#
# The RAID level + hotspare come from storage.conf itself — provision-
# storage.sh reads it directly — so nothing needs to be passed here.
###############################################################################
set -u

CONF=/etc/ustd/storage.conf
MARKER=/etc/ustd/has_setup_storage
PROVISION=/usr/local/sbin/provision-storage.sh

log() { echo "[provision-on-setup] $*"; }

# storage.conf not written yet -> operator hasn't reached the wizard step.
[ -f "$CONF" ] || exit 0

# usd's done-marker: storage already provisioned. Never auto-build again.
[ -e "$MARKER" ] && exit 0

# Act only once the operator has set "setup": true.
setup=$(python3 - "$CONF" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print("true" if d.get("setup") else "false")
PY
)
[ "${setup:-}" = "true" ] || exit 0

log "operator completed the storage wizard — provisioning the array"
if "$PROVISION" provision; then
    : > "$MARKER"
    log "array provisioned; wrote $MARKER"
else
    rc=$?
    log "provisioning failed (exit $rc) — setup flag left set for a retry"
    exit "$rc"
fi
