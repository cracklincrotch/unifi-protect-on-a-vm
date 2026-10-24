# Cloud brief: three follow-ups from the 2026-10-23 storage and snapshot work

Written 2026-10-24 by the local Claude Code session that operates this VM. You
(the cloud session) cannot reach the Mac host or the guest, so your job ends at a
pull request; the local session reviews it, deploys it and runs the live tests.

Background reading, in order: `README.md` (storage and control-channel sections),
`vm/storage/rootfs/usr/local/sbin/provision-storage.sh`,
`vm/storage/rootfs/etc/systemd/system/provision-storage.service`,
`host/control-host-helper.sh`, `host/snapshot.sh`, `vm-snapshot.py`,
`host/tests/test_snapshot_sh.sh`, and the last three commits (6fded24, 52b59e8,
a72de73), which explain the recent changes.

Guiding position from the owner (2026-10-23): "However the NVR does it should be
what we do here." The guest imitates a UniFi NVR, where the storage daemon (usd)
brings the array up before the Protect services start and retries when it cannot.
`provision-storage.service` now sits in usd's slot (DefaultDependencies=no,
After=local-fs-pre.target swap.target, Before=local-fs.target).

## 1. Swap UUID after an Erase

`provision()` runs `mkswap /dev/md0` without `-U`. The guest's `/etc/fstab` names
md0 swap by UUID, so after an Erase (re-provision) the new swap UUID no longer
matches and every boot waits about 90 s for a swap device that never appears.
Fix it so a re-provision keeps fstab and md0 in agreement: preferably reuse the
UUID that `/etc/fstab` already names for the md0 swap entry (`mkswap -U`), and when
fstab has no such entry, leave fstab alone. Handle a malformed or missing fstab
safely. Do not change how swap priorities work (`swapon -p 1`, NVMe swap pinned at
pri 100).

## 2. Degraded data array not mounted at boot

When md3 is degraded (a member missing), `do_boot` does not mount `/volume1`. Lead
to verify, not a conclusion: at boot `mdadm --assemble --scan` will not start an
array that is missing members, and the kernel or `mdadm-last-resort@` units start
it degraded only later, after `do_boot` has already fallen through to "disks with
existing data (NOT touched)" and exited. The NVR's usd would keep retrying.
Design and build the retry: bounded (never blocks boot indefinitely), never
provisions or writes to disks that carry data, mounts the array once it is
running (degraded is acceptable; log loudly), and copes with the Protect recorder
(`msr.service`) having already started without storage: it marks storage
non-operational until `systemctl restart msr.service`, so a late mount must
restart it. A systemd path or timer that re-runs boot mode, or a retry loop inside
boot mode, are both fine; explain the choice. Keep Erase/nuke unable to touch the
system disk (`is_system_disk`, `data_disks`).

## 3. Snapshot requests through the control channel

`host/control-host-helper.sh` `do_snapshot` calls `vm-snapshot.py` because
`snapshot.sh` used to fail (bare `qemu-img`, root image only, blind existence
check). 52b59e8 fixed `snapshot.sh`. Point `do_snapshot` back at `snapshot.sh`
(passing the conf path as its first argument, as the comments describe), keep the
idempotent "already exists, left as-is" behaviour correct for every image, keep
the label validation, update the comments, and decide whether `vm-snapshot.py` is
still needed by anything else (say so; do not delete it in this PR). Add tests to
`host/tests/` in the style of `test_snapshot_sh.sh` (stubbed commands; any check
against a real VM stays opt-in and read-only).

## Tests and constraints

- Shell changes need stubbed tests that run on Linux without root, disks or a VM.
  Run `host/tests/test_snapshot_sh.sh` before and after your change.
- Match the surrounding scripts' style and comment density; no new dependencies.
- This repository is public: no secrets, host credentials, IP addresses beyond
  what is already in it, or people's names.
- Plain hyphens only in docs, comments and the PR text (no em or en dashes).

## Deliverable

Branch `cloud/guest-followups`, one pull request against `main` with one commit per
item, titled "Guest follow-ups: swap UUID, degraded array retry, snapshot via
snapshot.sh". Before opening it, have an independent subagent review the diff for
correctness bugs and fix what it confirms. The PR description must give, per item:
what changed, how it was tested, what the live test on the real guest should be
(the local session will run it), review findings and their disposition, and open
questions. Do not merge.
