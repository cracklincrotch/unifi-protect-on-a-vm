#!/usr/bin/env python3
"""Consistent backup of the Protect VM's qcow2 images. Suspends for ~1 second.

Mirrors the Rocky9 procedure: suspend (QMP `stop`) -> `cp -cR` -> resume, and
let Time Machine back up the resulting static copy. ~/unifi-protect-on-a-vm is
tmutil-EXCLUDED because TM was backing up the LIVE images: an APFS snapshot is
atomic so the files were not torn, but qcow2 METADATA captured mid-L2-update is
unrecoverable, making those backups unverifiable. The clone written here is
quiescent, so it is the artifact TM should carry -- keep DEST included.

APFS clones are O(1) (measured: 2 GB in 0.008 s, both copies sharing 32K), so
there is no reason to copy bytes and no reason for the VM to be down for more
than the clone call itself. A suspended Protect VM records NOTHING from any of
the 42 cameras, so the script ALWAYS resumes, including on error.

`stop` halts the vCPUs so no writes are in flight -- that is what makes the copy
safe. RAM is NOT captured (that would be savevm, ~5 GB written into the qcow2
per run, too expensive here), so a restore boots as if power-cut. The guest page
cache is likewise unflushed: no qemu-guest-agent channel is configured, so this
is crash-consistent, which ext4 journal recovery handles. For a
restore-to-running-state point, run vm-snapshot.py first and the clone carries
that snapshot inside it.

SPACE: a clone starts near-free and GROWS toward the full image size as the live
VM overwrites shared blocks. That is why rocky9-backups reached 321 GB on five
dailies. Protect is ~97 GB of images, so keep very few: --keep defaults to 2.

  vm-clone-backup.py DEST [--keep N]
"""
import json, os, shutil, socket, subprocess, sys, time

QMP    = "/var/run/protect-vm.qmp.sock"
VMDATA = "/Users/donnie/unifi-protect-on-a-vm/vm-data"
IMAGES = ["protect.qcow2", "ssd1.qcow2"]
PREFIX = "protect-vm-"

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    dest = sys.argv[1]
    keep = int(sys.argv[sys.argv.index("--keep") + 1]) if "--keep" in sys.argv else 2
    if not os.path.isdir(dest):
        sys.exit("destination is not a directory: %s" % dest)
    for img in IMAGES:
        if not os.path.exists(os.path.join(VMDATA, img)):
            sys.exit("missing image: %s" % os.path.join(VMDATA, img))

    outdir = os.path.join(dest, PREFIX + time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(outdir, exist_ok=False)

    s = socket.socket(socket.AF_UNIX); s.settimeout(120); s.connect(QMP)
    f = s.makefile("rw"); f.readline()
    def cmd(c, **a):
        f.write(json.dumps({"execute": c, "arguments": a} if a else {"execute": c}) + "\n")
        f.flush()
        while True:
            r = json.loads(f.readline())
            if "return" in r or "error" in r: return r
    cmd("qmp_capabilities")

    st = cmd("query-status").get("return", {})
    if not st.get("running", True):
        f.close(); s.close()
        sys.exit("VM is not running (status=%s) -- refusing to touch it" % st.get("status"))

    # Once stopped the VM records nothing, so resume unconditionally.
    suspended = False
    try:
        t0 = time.time()
        r = cmd("stop")
        if "error" in r: sys.exit("could not suspend: %s" % r["error"])
        suspended = True
        for img in IMAGES:
            subprocess.run(["cp", "-cR", os.path.join(VMDATA, img),
                            os.path.join(outdir, img)], check=True)
        r = cmd("cont")
        if "error" in r: sys.exit("RESUME FAILED -- VM IS SUSPENDED: %s" % r["error"])
        suspended = False
        print("  suspended for %.3f s -> %s" % (time.time() - t0, outdir))
    finally:
        if suspended:
            try:
                cmd("cont"); print("  resumed after error")
            except Exception as e:
                print("  *** COULD NOT RESUME, VM IS SUSPENDED: %s" % e)
        f.close(); s.close()

    # Prune oldest. Clones grow as the live images diverge, so this is not
    # optional housekeeping -- it is what stops DEST becoming rocky9-backups.
    olds = sorted(d for d in os.listdir(dest)
                  if d.startswith(PREFIX) and os.path.isdir(os.path.join(dest, d)))
    for d in olds[:-keep] if keep > 0 else []:
        shutil.rmtree(os.path.join(dest, d)); print("  pruned %s" % d)
    print("  kept %d backup(s)" % min(len(olds), keep))

main()
