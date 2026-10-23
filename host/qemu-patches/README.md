# Patched QEMU for raw-disk fdsets on macOS

`start-protect-vm.sh` runs with `DISK_FDSET=1` by default: the DAS drives reach
QEMU as `/dev/fdset/N`, opened by `qemu-fdset-exec.py`, so a drive that drops
off USB and comes back under a new `/dev/diskN` can be handed to the paused VM
with `add-fd` + `blockdev-reopen` instead of a restart and a RAID resync.

Stock QEMU cannot do that on macOS. Darwin rejects `fcntl(F_SETFL)` on a raw
disk device with `ENOTTY` for every value, and QEMU treats that as fatal in
two places:

| patch | function | without it |
|---|---|---|
| `0001-...osdep...patch` | `qemu_dup_flags()` in `util/osdep.c` | an fdset cannot open a device at all: `Failed to dup() given file descriptor` |
| `0002-...oslib-posix...patch` | `qemu_set_blocking()` in `util/oslib-posix.c` | any `SCM_RIGHTS` message carrying a device descriptor drops the QMP connection, which kills `add-fd` |

Both are one-line "tolerate ENOTTY" changes. Upstream has neither (checked
against 11.1.2 and master, 2026-10-23); both apply unchanged to 11.1.0 and
11.1.2.

## Build

```
./build.sh 11.1.2
```

On the Mac that runs the VM. It verifies the tarball, applies the patches,
builds, checks the hypervisor entitlement and runs `test_qemu_enotty.py`, which
attaches a scratch raw disk and proves both patches (a stock build fails at
step 1). Nothing is installed.

## Swap in (planned restart)

1. `touch /usr/local/var/protect-maintenance` (as root) to quiet the recording watchdog.
2. Keep the old binary: `mv ~/qemu-patched/qemu-system-aarch64 ~/qemu-patched/qemu-system-aarch64.<old>`,
   then copy the new one to `~/qemu-patched/qemu-system-aarch64` (that is `QEMU_BIN`).
3. The binary finds its ROMs in `../share/qemu` relative to itself: refresh
   `~/share/qemu` from `$(brew --prefix qemu)/share/qemu`, keeping the old copy.
4. Clean ACPI power-down through QMP, wait until launchd shows the job not
   running with exit 0 (`sudo launchctl print system/com.protect-on-mac.vm`;
   QEMU runs as root, so an unprivileged `kill -0` falsely says it exited), then
   `sudo launchctl kickstart system/com.protect-on-mac.vm`.
5. Check: RAID clean, all media services logging to `/volume1/.srv/ms/logs`,
   cameras writing video; then remove the maintenance file.

Rollback is the same swap in reverse.

**Full Disk Access.** Under launchd, macOS charges the DAS open to the
interpreter that runs `qemu-fdset-exec.py`, i.e. the exact Homebrew Python
binary path. A Homebrew Python patch upgrade changes that path and the VM will
fail to start (`Operation not permitted` on `/dev/rdiskN`) until the new
`.../Cellar/python@3.x/<ver>/Frameworks/Python.framework/Versions/3.x/bin/python3.x`
is granted Full Disk Access. Do not `brew cleanup` the old Python before that.
