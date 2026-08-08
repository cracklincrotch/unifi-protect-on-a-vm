#!/usr/bin/env python3
"""Live snapshot of the Protect VM via QMP — works while the VM is running.

Why not snapshot.sh: macOS sudo strips /opt/homebrew from PATH so its bare
`qemu-img` calls fail silently. And a naive savevm fails here because the raw
DAS passthrough disks can't hold snapshots — so we scope the save to the qcow2
block node only, discovering its (auto-generated, per-boot) name each time.

  vm-snapshot.py                 list snapshots
  vm-snapshot.py TAG             create snapshot TAG
  vm-snapshot.py --delete TAG    delete snapshot TAG
"""
import json, socket, subprocess, sys, time

QMP   = "/var/run/protect-vm.qmp.sock"
QCOW2 = "/Users/donnie/unifi-protect-on-a-vm/vm-data/protect.qcow2"
QIMG  = "/opt/homebrew/bin/qemu-img"

def qmp():
    s = socket.socket(socket.AF_UNIX); s.settimeout(600); s.connect(QMP)
    f = s.makefile("rw"); f.readline()
    def cmd(c, **a):
        f.write(json.dumps({"execute": c, "arguments": a} if a else {"execute": c}) + "\n")
        f.flush()
        while True:
            r = json.loads(f.readline())
            if "return" in r or "error" in r: return r
    cmd("qmp_capabilities")
    return cmd

def qcow2_node(cmd):
    for n in cmd("query-named-block-nodes").get("return", []):
        if n.get("drv") == "qcow2" and n.get("file", "").endswith("protect.qcow2"):
            return n["node-name"]
    sys.exit("could not find the qcow2 block node")

def listing():
    out = subprocess.run(["sudo", QIMG, "snapshot", "-l", "-U", QCOW2],
                         capture_output=True, text=True)
    print(out.stdout or out.stderr)

if len(sys.argv) == 1:
    listing(); sys.exit()

if sys.argv[1] == "--delete":
    tag = sys.argv[2]
    cmd = qmp(); node = qcow2_node(cmd)
    jid = "del%d" % int(time.time())
    r = cmd("snapshot-delete", **{"job-id": jid, "tag": tag, "devices": [node]})
    if "error" in r: sys.exit("delete failed: %s" % r["error"])
else:
    tag = sys.argv[1]
    cmd = qmp(); node = qcow2_node(cmd)
    print("  qcow2 node: %s" % node)
    print("  creating snapshot %r (VM stays running)..." % tag)
    jid = "snap%d" % int(time.time())
    r = cmd("snapshot-save", **{"job-id": jid, "tag": tag,
                                "vmstate": node, "devices": [node]})
    if "error" in r: sys.exit("snapshot-save rejected: %s" % r["error"])

# wait for the job
while True:
    jobs = [j for j in cmd("query-jobs").get("return", []) if j["id"] == jid]
    if not jobs: break
    j = jobs[0]
    if j["status"] in ("concluded", "aborting", "null"):
        if j.get("error"): sys.exit("  FAILED: %s" % j["error"])
        cmd("job-dismiss", id=jid); break
    time.sleep(2)
print("  done.\n")
listing()
