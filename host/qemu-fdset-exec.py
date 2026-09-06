#!/usr/bin/env python3
"""Open block devices as root, then exec QEMU with them as /dev/fdset members.

    qemu-fdset-exec.py --fd <setid>:<path> [--nocache-fd <setid>:<path>] ... -- <qemu> <args...>

--nocache-fd is --fd plus fcntl(F_NOCACHE) on the descriptors: for regular
files (the qcow2 images) it keeps guest disk pages out of the host's buffer
cache. Per-descriptor, inherited across the exec below.

Why this exists: the launcher runs as an unprivileged user and reaches root via
sudo, and sudo closes every descriptor >= 3. So a descriptor opened before the
privilege change never reaches QEMU. This runs AFTER sudo, opens the devices
itself, and execs QEMU directly -- nothing has to cross the sudo boundary.

The point of fdset at all: when the DAS re-enumerates onto new /dev/diskN, the
descriptors QEMU holds are dead permanently -- they reference the device
instances that went away, not the paths. Today the only escape is a cold
restart, which leaves the array dirty and costs a resync. With the drives
backed by an fdset, a new descriptor for the new node can be handed to a
RUNNING, PAUSED QEMU via add-fd + blockdev-reopen, and the guest -- which
accrues no SCSI timeouts while paused -- resumes onto healthy descriptors with
the array still clean.

Fds are marked inheritable explicitly; Python sets O_CLOEXEC on os.open by
default, which would silently reproduce the very problem this exists to solve.
"""
import fcntl
import os
import resource
import sys


def main():
    argv = sys.argv[1:]
    if "--" not in argv:
        sys.exit("qemu-fdset-exec: missing -- separator before the qemu command")
    split = argv.index("--")
    spec, cmd = argv[:split], argv[split + 1:]
    if not cmd:
        sys.exit("qemu-fdset-exec: no qemu command given")

    pairs = []
    i = 0
    while i < len(spec):
        if spec[i] not in ("--fd", "--nocache-fd"):
            sys.exit("qemu-fdset-exec: unexpected argument %r" % spec[i])
        if i + 1 >= len(spec):
            sys.exit("qemu-fdset-exec: %s needs <setid>:<path>" % spec[i])
        setid, _, path = spec[i + 1].partition(":")
        if not setid.isdigit() or not path:
            sys.exit("qemu-fdset-exec: bad %s value %r" % (spec[i], spec[i + 1]))
        pairs.append((int(setid), path, spec[i] == "--nocache-fd"))
        i += 2

    # QEMU dup()s every descriptor registered with -add-fd, so the process
    # needs headroom for twice what we hand it, on top of pflash, the qcow2,
    # virtio, netdev, console, QMP and control sockets. A first attempt failed
    # with "Failed to dup() given file descriptor fd=14", and EMFILE is the
    # reading that fits: the same wrapper works standalone with four sets.
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = 4096 if hard == resource.RLIM_INFINITY else min(4096, hard)
    if soft < want:
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
            sys.stderr.write("nofile raised %s -> %s (hard %s)\n" % (soft, want, hard))
        except (ValueError, OSError) as exc:
            sys.stderr.write("could not raise nofile from %s: %s\n" % (soft, exc))
    else:
        sys.stderr.write("nofile soft=%s hard=%s (unchanged)\n" % (soft, hard))

    def open_with_unmount(path, mode):
        """Open a raw disk, force-unmounting its volumes if something races us.

        /etc/fstab noauto SHOULD keep the marker partitions unmounted, but on
        macOS 26 the msdos mounter runs through FSKit (mount flag `fskit`) and
        demonstrably remounts them anyway -- all four were mounted seconds
        after the launcher's own diskutil unmountDisk pass, and the open here
        then fails EBUSY. Unmounting at the last instant, as root, in the same
        process that opens the device, closes that race for good.
        """
        import errno
        import subprocess
        for attempt in range(3):
            try:
                return os.open(path, mode)
            except OSError as exc:
                if exc.errno != errno.EBUSY:
                    raise
                sys.stderr.write("%s busy; force-unmounting (attempt %d)\n"
                                 % (path, attempt + 1))
                subprocess.run(["diskutil", "unmountDisk", "force", path],
                               capture_output=True)
        return os.open(path, mode)          # final try; let EBUSY surface

    addfd = []
    for setid, path, nocache in pairs:
        # BOTH access modes go into the set. QEMU matches a descriptor by its
        # access mode rather than accepting a more permissive one, so an
        # O_RDWR-only set is rejected with
        #   Failed to find file descriptor with matching flags=0x0
        # (0x0 being O_RDONLY) the moment anything opens the image read-only.
        # Holding one of each is what fdsets are for, and it is also what lets
        # a later blockdev-reopen pick the mode it needs.
        for mode in (os.O_RDWR, os.O_RDONLY):
            try:
                fd = open_with_unmount(path, mode)
            except OSError as exc:
                sys.exit("qemu-fdset-exec: cannot open %s: %s" % (path, exc))
            if nocache:
                # Regular files only: keep guest disk pages out of the host's
                # unified buffer cache -- the guest has its own. The flag lives
                # on the open file description, so it survives QEMU's dup() and
                # F_GETFL/F_SETFL round-trip (verified 2026-09-06).
                try:
                    fcntl.fcntl(fd, fcntl.F_NOCACHE, 1)
                except OSError as exc:
                    # Degrade to the cached path rather than dying before the
                    # exec: a wrapper failure here would put launchd into a
                    # 30 s relaunch loop with the guest down.
                    sys.stderr.write("F_NOCACHE on %s failed (%s); continuing cached\n" % (path, exc))
                    nocache = False
            os.set_inheritable(fd, True)   # os.open sets O_CLOEXEC by default
            addfd += ["-add-fd", "fd=%d,set=%d,opaque=%s" % (fd, setid, path)]
        sys.stderr.write("fdset %d <- %s (rw+ro%s)\n"
                         % (setid, path, ", nocache" if nocache else ""))

    # Prove every descriptor is still open and inheritable at the moment of
    # exec. If QEMU then says it cannot dup one of these, the descriptor was
    # fine here and the failure is on QEMU's side, which is worth knowing.
    for i in range(0, len(addfd), 2):
        fd = int(addfd[i + 1].split(",")[0].split("=")[1])
        try:
            os.fstat(fd)
            ok = os.get_inheritable(fd)
        except OSError as exc:
            ok = "FSTAT FAILED: %s" % exc
        sys.stderr.write("  pre-exec fd=%d inheritable=%s\n" % (fd, ok))

    # -add-fd must precede the -drive lines that reference /dev/fdset/N.
    full = [cmd[0]] + addfd + cmd[1:]
    sys.stderr.flush()
    try:
        os.execv(cmd[0], full)
    except OSError as exc:
        sys.exit("qemu-fdset-exec: exec %s failed: %s" % (cmd[0], exc))


if __name__ == "__main__":
    main()
