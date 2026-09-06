#!/usr/bin/env python3
"""Live snapshot of the Protect VM via QMP — works while the VM is running.

Why not snapshot.sh: macOS sudo strips /opt/homebrew from PATH so its bare
`qemu-img` calls fail silently (its `list` reports "image unreadable" on an
image holding six snapshots). And a naive savevm fails here because the raw
DAS passthrough disks can't hold snapshots — so we scope the save to the qcow2
block nodes only, discovering their (auto-generated, per-boot) names each time.
EVERY qcow2 image is included -- root AND /ssd1, where the database lives.

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

def qcow2_nodes(cmd):
    """(vmstate_node, [every qcow2 node], {node: file}).

    ALL qcow2 images go into one snapshot job, not just the root disk. Since
    2026-08-03 the Protect DATABASE lives on /ssd1 = ssd1.qcow2; a snapshot
    of protect.qcow2 alone restores the binaries but leaves a database that a
    newer Protect has already migrated -- a rollback that does not roll back.
    One job with both devices is a single consistent point in time; the
    vmstate (RAM) rides in the root image. Raw DAS passthrough and pflash are
    not qcow2 and are correctly left out.
    """
    # The images reach QEMU through fdsets (opened uncached on the host by
    # qemu-fdset-exec.py), so a node's "file" reads /dev/fdset/N; the wrapper
    # records the real path as each fdset's opaque string.
    fdpath = {}
    for st in cmd("query-fdsets").get("return", []):
        for e in st.get("fds", []):
            if e.get("opaque"):
                fdpath["/dev/fdset/%d" % st["fdset-id"]] = e["opaque"]
    root, nodes, files = None, [], {}
    for n in cmd("query-named-block-nodes").get("return", []):
        if n.get("drv") != "qcow2":
            continue
        f = fdpath.get(n.get("file", ""), n.get("file", ""))
        nodes.append(n["node-name"]); files[n["node-name"]] = f
        if f.endswith("protect.qcow2"):
            root = n["node-name"]
    if not root:
        sys.exit("could not find the root qcow2 block node")
    return root, nodes, files

def listing(images=None):
    # Never open a second QMP connection while one is live: QEMU's QMP server
    # takes one client at a time and a second connect BLOCKS (it does not
    # fail), which hung this tool after a successful delete -- while holding
    # the very socket the DAS reattach helper depends on. Callers that already
    # hold a connection pass the image list in.
    if images is None:
        images = all_images()
    for img in sorted({QCOW2} | set(images)):
        print("=== %s ===" % img)
        out = subprocess.run(["sudo", QIMG, "snapshot", "-l", "-U", img],
                             capture_output=True, text=True)
        print(out.stdout or out.stderr)

def all_images():
    try:
        cmd = qmp()
        return [f for f in qcow2_nodes(cmd)[2].values() if f]
    except Exception:
        return []

if len(sys.argv) == 1:
    listing(); sys.exit()

if sys.argv[1] == "--delete":
    tag = sys.argv[2]
    cmd = qmp(); root, nodes, files = qcow2_nodes(cmd)
    jid = "del%d" % int(time.time())
    r = cmd("snapshot-delete", **{"job-id": jid, "tag": tag, "devices": nodes})
    if "error" in r: sys.exit("delete failed: %s" % r["error"])
else:
    tag = sys.argv[1]
    cmd = qmp(); root, nodes, files = qcow2_nodes(cmd)
    for n in nodes:
        print("  %s  %s%s" % (n, files[n], "  (vmstate)" if n == root else ""))
    print("  creating snapshot %r across %d image(s) (VM stays running)..."
          % (tag, len(nodes)))
    jid = "snap%d" % int(time.time())
    r = cmd("snapshot-save", **{"job-id": jid, "tag": tag,
                                "vmstate": root, "devices": nodes})
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
listing(list(files.values()))
