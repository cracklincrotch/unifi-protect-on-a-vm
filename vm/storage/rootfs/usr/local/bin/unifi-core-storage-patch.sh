#!/bin/bash
###############################################################################
# unifi-core-storage-patch.sh
#
# Re-applies the ustorage.disks patch to unifi-core's bundled service.js.
#
# WHY
#
# unifi-core's `system.ustorage.inspect` handler hardcodes `disks:[]` and only
# ever calls `ustorage space inspect`. The patch makes it also call
# `ustorage disk inspect` (served by ustorage-vm.py) so the Storage panel's
# disk list populates. service.js is a vendor bundle — a unifi-core update
# overwrites it and reverts the patch. This script restores it.
#
# It is idempotent and safe to run on every boot (see the systemd unit). It
# never fails the boot: any unexpected state degrades to a no-op exit 0.
###############################################################################
set -u

SVC=/usr/share/unifi-core/app/service.js
ANCHOR='t={space:c,disks:[],sdcards:[]};'
MARKER='["disk","inspect"]'
REPLACEMENT='let dd=[];try{dd=JSON.parse((await J("ustorage",["disk","inspect"])).stdout);}catch(_){va.error("Failed to retrieve disk info via ustorage:",_);}t={space:c,disks:dd,sdcards:[]};'

if [ ! -f "$SVC" ]; then
    echo "storage-patch: $SVC not found — skipping"
    exit 0
fi

if grep -qF "$MARKER" "$SVC"; then
    echo "storage-patch: already applied"
    exit 0
fi

python3 - "$SVC" "$ANCHOR" "$REPLACEMENT" <<'PY'
import sys
path, anchor, repl = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
n = s.count(anchor)
if n != 1:
    sys.stderr.write("storage-patch: expected exactly 1 anchor, found %d — NOT patching\n" % n)
    sys.exit(0)
open(path + ".prepatch", "w").write(s)
open(path, "w").write(s.replace(anchor, repl, 1))
print("storage-patch: applied (original saved to %s.prepatch)" % path)
PY
