#!/usr/bin/env python3
"""Reattach a PAUSED (or running) QEMU to re-enumerated DAS disks. Root.

    qmp-das-reattach.py --map <disk-serial.map> [--qmp <socket>] [--check]
                        [--window <seconds>]

This is the payoff of the whole fdset design. When the DAS bus faults, macOS
re-enumerates the disks onto NEW /dev/diskN nodes and every descriptor QEMU
holds is dead permanently -- they reference the device instances that went
away, not the paths. werror=stop has already frozen the guest safely (a paused
guest accrues no SCSI timeouts; QEMU stops its clock), so the array is intact
but recording is stopped. Until now the only exit was a cold restart, which
cannot mark md clean -- that is itself a write to the dead disks -- so every
bus event cost a multi-day resync.

With the drives backed by /dev/fdset/N and named block nodes (DISK_FDSET=1 in
start-protect-vm.sh), the descriptors can be replaced at runtime instead:

    1. re-resolve each ATA serial to whatever /dev/diskN it came back as
    2. force-unmount it (the FAT marker partitions auto-mount on arrival --
       macOS 26's FSKit msdos mounter ignores fstab noauto)
    3. open fresh rw+ro descriptors and add-fd them into the drive's fdset
       (delivered over SCM_RIGHTS on the QMP socket)
    4. remove-fd the stale descriptors
    5. blockdev-reopen the file_<SERIAL> node -- the filename string is
       UNCHANGED (/dev/fdset/N), only the descriptors underneath are new
    6. cont -- the writes werror=stop suspended retry against live disks

The guest never sees a device leave: no md kick, no dirty array, no resync.

Requires the QEMU pointed at by QEMU_BIN to carry the two ENOTTY patches
(qemu_dup_flags and qemu_set_blocking) -- stock QEMU on macOS fails step 3/5.

--check resolves and reports but changes nothing.

Exit 0 on success, non-zero on failure (callers fall back to halt+relaunch).
"""
import argparse
import array
import errno
import json
import os
import socket
import subprocess
import sys
import time

SMARTCTL = "/opt/homebrew/bin/smartctl"


def log(msg):
    sys.stderr.write("[das-reattach] %s\n" % msg)
    sys.stderr.flush()


class Qmp:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(20)
        self.sock.connect(path)
        self.buf = b""
        self._readline()                      # greeting
        self.cmd("qmp_capabilities")

    def _readline(self):
        while b"\n" not in self.buf:
            d = self.sock.recv(65536)
            if not d:
                raise RuntimeError("QMP connection closed")
            self.buf += d
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def cmd(self, name, scm_fd=None, **args):
        msg = json.dumps({"execute": name, "arguments": args}
                         if args else {"execute": name}) + "\n"
        if scm_fd is None:
            self.sock.sendall(msg.encode())
        else:
            self.sock.sendmsg([msg.encode()],
                              [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                array.array("i", [scm_fd]))])
        while True:
            r = self._readline()
            if "event" in r:
                continue                      # interleaved async events
            if "error" in r:
                raise RuntimeError("%s: %s" % (name, r["error"].get("desc")))
            return r.get("return")


def external_disks():
    out = subprocess.run(["diskutil", "list"], capture_output=True,
                         text=True).stdout
    return [l.split()[0] for l in out.splitlines()
            if l.startswith("/dev/disk") and "(external, physical)" in l]


def serial_of(dev):
    try:
        out = subprocess.run([SMARTCTL, "-j", "-a", dev], capture_output=True,
                             text=True, timeout=30).stdout
        return (json.loads(out or "{}")).get("serial_number") or ""
    except Exception:
        return ""


def resolve_all(serials):
    """serial -> /dev/diskN for every serial, or None if any is missing."""
    found = {}
    for dev in external_disks():
        s = serial_of(dev)
        if s in serials:
            found[s] = dev
    return found if len(found) == len(serials) else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", required=True, help="disk-serial.map path")
    ap.add_argument("--qmp", default="/var/run/protect-vm.qmp.sock")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--window", type=int, default=600,
                    help="seconds to keep waiting for the disks to return")
    a = ap.parse_args()

    serials = []
    with open(a.map) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[1] == "disk":
                serials.append(parts[0])
    if not serials:
        log("no raw disks in %s" % a.map)
        return 2
    log("raw disks: %s" % " ".join(serials))

    deadline = time.time() + a.window
    mapping = resolve_all(serials)
    while mapping is None:
        if time.time() > deadline:
            log("disks did not all return within %ds" % a.window)
            return 3
        log("waiting for the bus (found %d of %d)..."
            % (len(resolve_all(serials) or {}), len(serials)))
        time.sleep(10)
        mapping = resolve_all(serials)
    for s, d in sorted(mapping.items()):
        log("resolved %s -> %s" % (s, d))

    q = Qmp(a.qmp)

    # serial -> fdset id, from the node graph: file_<SERIAL> is backed by
    # /dev/fdset/<N>. Read it rather than assuming creation order.
    nodes = q.cmd("query-named-block-nodes")
    setid = {}
    for n in nodes:
        nm = n.get("node-name", "")
        if nm.startswith("file_") and n.get("file", "").startswith("/dev/fdset/"):
            setid[nm[5:]] = int(n["file"].rsplit("/", 1)[1])
    missing = [s for s in serials if s not in setid]
    if missing:
        log("no fdset-backed node for: %s (DISK_FDSET off?)" % " ".join(missing))
        return 4

    fdsets = {st["fdset-id"]: [e["fd"] for e in st.get("fds", [])]
              for st in q.cmd("query-fdsets")}

    if a.check:
        for s in serials:
            log("CHECK %s: node file_%s fdset=%d holds %s, disk now %s"
                % (s, s, setid[s], fdsets.get(setid[s]), mapping[s]))
        return 0

    for s in serials:
        dev, sid = mapping[s], setid[s]
        # The marker FAT partitions mount themselves on arrival (FSKit ignores
        # fstab noauto); a mounted volume makes the open below fail EBUSY.
        subprocess.run(["diskutil", "unmountDisk", "force", dev],
                       capture_output=True)
        stale = fdsets.get(sid, [])
        for mode, label in ((os.O_RDWR, "rw"), (os.O_RDONLY, "ro")):
            fd = os.open(dev, mode)
            try:
                r = q.cmd("add-fd", scm_fd=fd, **{"fdset-id": sid,
                                                  "opaque": dev + "-" + label})
                log("%s: add-fd %s -> fd %s" % (s, label, r.get("fd")))
            finally:
                os.close(fd)
        for fd in stale:
            q.cmd("remove-fd", **{"fdset-id": sid, "fd": fd})
        log("%s: dropped stale fds %s" % (s, stale))
        q.cmd("blockdev-reopen", options=[{
            "driver": "host_device",
            "node-name": "file_" + s,
            "filename": "/dev/fdset/%d" % sid,
            "auto-read-only": False,
        }])
        log("%s: blockdev-reopen OK (filename unchanged, descriptors new)" % s)

    q.cmd("cont")
    log("cont sent -- suspended writes now retry against live descriptors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
