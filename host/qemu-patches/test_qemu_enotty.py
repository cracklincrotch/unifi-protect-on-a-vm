"""Does a qemu-system-aarch64 binary carry the two macOS ENOTTY patches?

usage: python3 test_qemu_enotty.py /path/to/qemu-system-aarch64

Attaches a 16 MB scratch image as a RAW disk device (hdiutil), then:
  1. opens it through an fdset (/dev/fdset/1)          -> needs patch 0001
  2. hands QEMU fresh device descriptors with add-fd   -> needs patch 0002
  3. drops the stale ones and blockdev-reopens the node
A stock QEMU fails at step 1 ("Failed to dup() given file descriptor").
Exit 0 only if all steps work. (Harness from the 2026-08-18 build session.)
"""
import os, sys, json, socket, array, subprocess, time, tempfile

QEMU = sys.argv[1]
D = tempfile.mkdtemp(prefix="enotty.")
IMG, SOCK, ERR = D + "/f.img", D + "/q.sock", D + "/q.err"


class Q:
    def __init__(s_, p):
        s_.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s_.s.settimeout(10)
        s_.s.connect(p); s_.b = b""; s_.rl()

    def rl(s_):
        while b"\n" not in s_.b:
            d = s_.s.recv(65536)
            if not d:
                raise RuntimeError("QMP closed")
            s_.b += d
        l, s_.b = s_.b.split(b"\n", 1); return json.loads(l)

    def cmd(s_, c, _scm=None, **kw):
        m = json.dumps({"execute": c, "arguments": kw} if kw else {"execute": c}) + "\n"
        if _scm is None:
            s_.s.sendall(m.encode())
        else:
            s_.s.sendmsg([m.encode()], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [_scm]))])
        while True:
            r = s_.rl()
            if "event" not in r:
                return r


subprocess.run(["dd", "if=/dev/zero", "of=" + IMG, "bs=1m", "count=16"], capture_output=True)
node = [l.split()[0] for l in subprocess.run(
    ["hdiutil", "attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", IMG],
    capture_output=True, text=True).stdout.splitlines() if l.startswith("/dev/disk")][0]
print("  raw device: %s   qemu: %s" % (node, QEMU))
ok = False
pid = None
try:
    fds = []
    for m in (os.O_RDWR, os.O_RDONLY):
        fd = os.open(node, m); os.set_inheritable(fd, True); fds.append(fd)
    args = [QEMU]
    for fd in fds:
        args += ["-add-fd", "fd=%d,set=1,opaque=orig" % fd]
    args += ["-machine", "none", "-display", "none", "-nodefaults",
             "-blockdev", "driver=host_device,node-name=dasfile,filename=/dev/fdset/1,auto-read-only=off",
             "-blockdev", "driver=raw,node-name=das0,file=dasfile",
             "-qmp", "unix:%s,server=on,wait=off" % SOCK]
    pid = os.fork()
    if pid == 0:
        e = os.open(ERR, os.O_WRONLY | os.O_CREAT | os.O_TRUNC); os.dup2(e, 2); os.dup2(e, 1)
        os.execv(QEMU, args)
    for _ in range(40):
        if os.path.exists(SOCK) or os.waitpid(pid, os.WNOHANG)[0]:
            break
        time.sleep(0.25)
    if not os.path.exists(SOCK):
        print("  STEP 1  FAILED: QEMU did not start: %s" % open(ERR).read().strip()[-200:])
        pid = None
        sys.exit(1)
    try:
        q = Q(SOCK); q.cmd("qmp_capabilities")
    except OSError:
        time.sleep(0.5)
        print("  STEP 1  FAILED: QEMU exited: %s" % open(ERR).read().strip()[-200:])
        pid = None
        sys.exit(1)

    def sz():
        for n in q.cmd("query-named-block-nodes").get("return", []):
            if n.get("node-name") == "das0":
                return n.get("image", {}).get("virtual-size")

    def held():
        return [e["fd"] for st in q.cmd("query-fdsets").get("return", [])
                if st["fdset-id"] == 1 for e in st["fds"]]

    print("  STEP 1  opened via fdset: das0 size=%s" % sz())
    old = held()
    for m, lab in ((os.O_RDWR, "rw"), (os.O_RDONLY, "ro")):
        fd = os.open(node, m)
        r = q.cmd("add-fd", _scm=fd, **{"fdset-id": 1, "opaque": "fresh-" + lab})
        os.close(fd)
        print("  STEP 2  add-fd %s -> %s" % (lab, json.dumps(r.get("return", r))[:70]))
    for fd in old:
        q.cmd("remove-fd", **{"fdset-id": 1, "fd": fd})
    r = q.cmd("blockdev-reopen", options=[{"driver": "host_device", "node-name": "dasfile",
                                            "filename": "/dev/fdset/1", "auto-read-only": False}])
    print("  STEP 3  blockdev-reopen -> %s; das0 size=%s" % (json.dumps(r)[:60], sz()))
    ok = r.get("return") is not None and sz() == 16777216
    try:
        q.cmd("quit")
    except Exception:
        pass
except RuntimeError as e:
    print("  FAILED: %s" % e)
finally:
    time.sleep(1)
    if pid:
        try:
            os.kill(pid, 9)
        except OSError:
            pass
    subprocess.run(["hdiutil", "detach", node], capture_output=True)
    subprocess.run(["rm", "-rf", D])
print("  RESULT: %s" % ("both ENOTTY patches present and working" if ok else "FAILED"))
sys.exit(0 if ok else 1)
