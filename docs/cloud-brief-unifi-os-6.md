# Cloud brief: what would UniFi OS 6.0 do to this VM?

Written 2026-10-24 by the local Claude Code session that operates this VM. You
(the cloud session) cannot reach the Mac host, the guest or the cameras. Your job is
analysis and a pull request; nothing is installed anywhere. The local session will
test on an isolated clone of the VM afterwards.

## Where we are

The guest runs UniFi OS 5.1.33 (UNVR firmware, packages repacked by
`vm/installers/update-unifi.sh --sync-os`) with Protect 7.3.70 installed on its own
(`--protect`). The project's own code (shims, wrappers, the storage subsystem) lives
in standalone installers, deliberately NOT inside Ubiquiti's packages; keep it that way.

Read first: `README.md`, `vm/installers/update-unifi.sh`, the other installers in
`vm/installers/`, everything under `vm/*/rootfs/` (systemd units and drop-ins, shims,
`provision-storage.sh`), and the last commits (6fded24 moved the storage provisioner
into usd's slot: DefaultDependencies=no, Before=local-fs.target).

## Do

1. Use the same firmware API `update-unifi.sh` uses to find and download the UNVR
   firmware for 6.0 (latest 6.0.x) and for 5.1.33. Verify the SHA256 as the script
   does. If your network blocks the download, stop and say so in the PR; do not use
   unofficial mirrors.
2. Unpack both (follow the script's extraction steps). Never commit firmware,
   packages or Ubiquiti binaries; only your report and code.
3. Compare, and for each item say "unchanged / changed, harmless / changed, breaks us
   because ... / needs a change in <file>":
   - package list and versions (new, removed, renamed), Debian base release, kernel
     packages the script excludes (`linux-image`, `unvr-initramfs`), Postgres major
     (and whether Protect's database would be migrated), Node version;
   - every systemd unit the repo masks, overrides, replaces or orders against: usd,
     usdbd, ustated, msr, ms, msp, mst, unifi-core, ulp-go, postgresql@*-protect,
     local-fs ordering, and whether usd's slot still exists as we use it;
   - every path and field our shims and patches read or write (ubnt-tools fields
     such as serial/uuid/board ids, the unifi-core storage patch, the msr/ms drop-ins,
     the anonymous device id seeding, ustated shim);
   - new hardware queries or checks at boot or during setup that a VM would fail;
   - the update mechanism itself: does `update-unifi.sh` still parse the 6.0
     firmware and API responses?
4. Where cheap, spot-check 6.0 binaries the shims depend on under qemu-user in a
   chroot (no full boot).
5. Make the code changes 6.0 would need in the repo (update script, installers,
   drop-ins), each guarded so 5.1.33 keeps working, with stubbed tests that run on
   Linux without root or a VM.

## Deliverable

Branch of your choice, one pull request against `main` titled
"UniFi OS 6.0: compatibility report and required changes". Add the report as
`docs/unifi-os-6-compat.md`. The PR description must give: a go / no-go opinion, the
list of breaking items with evidence, what the code changes cover, and a step-by-step
test plan for an ISOLATED clone (no network path to cameras or the live console; the
console identity must not be duplicated online). Before opening it, have an
independent subagent review the diff and the report; fix what it confirms.

Constraints: public repo, so no secrets, credentials, internal addresses beyond those
already in the repo, or people's names. Plain hyphens only. Do not merge.
