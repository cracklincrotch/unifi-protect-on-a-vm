# UniFi OS 6.0 on this VM: compatibility report

Written 2026-10-24 by a cloud session, from the UNVR firmware images only (no
guest, host or camera access). Compared: **UniFi OS 5.1.33** (what the guest
runs, with Protect 7.3.70) against **UniFi OS 6.0.11**, the only 6.x build the
firmware API publishes on any channel. Nothing from Ubiquiti is committed; every
result below can be reproduced with the commands in [Method](#method).

## Verdict

- **No-go for `--sync-os` to 6.0 on the current VM.** 6.0 rebased the UNVR
  firmware from Debian 11 (bullseye) onto Debian 13 (trixie). Its Ubiquiti
  packages are built against trixie (glibc >= 2.38/2.39, libssl3t64,
  libstdc++6 >= 13/14, libfmt10, libgpiod3 ...). On the VM's Debian 11
  userland apt refuses 24 of them, so nothing installs. This cannot be fixed
  inside the repacking approach; it needs a Debian 13 guest.
- **Urgent, and fixed in this PR:** 6.0.11 is the API's `firmware-latest`
  for UNVR since 2026-10-07. Before this PR, `update-unifi.sh --sync-os` (or
  `--all`) on the live VM would have stopped Protect, failed apt, carried on,
  stamped `/usr/lib/version` with 6.0.11 and restarted the stack. unifi-core
  reports that file as the console's `firmwareVersion`, so the console would
  have shown 6.0.11 while running 5.1.33. A fresh
  `install-protect-baremetal.sh` run would also pull 6.0.11 and fail in
  Phase 5, after writing the 6.0.11 version file.
- **Go for staying on 5.1.x for now.** Protect 7.3.70, Access 4.3.22, ms/msr
  5.1.317 and ds 7.3.6 are still published for `uos-deb11-arm64`, the same
  versions as for `uos-deb13-arm64`. Nothing forces 6.0 today.
- **Plan the Debian 13 move anyway.** Debian 11 LTS ended on 2026-08-31
  ([announcement](https://www.debian.org/News/2026/20260831)); the guest gets no
  Debian security updates now. The real deadline is the first Protect release
  without a `uos-deb11-arm64` build. On the Ubiquiti side the 6.0 changes that
  touch this project are small (below); the large job is the guest's base OS.

## Breaking items

| # | Item | Evidence | Status |
|---|------|----------|--------|
| 1 | Debian 11 -> 13 rebase | `etc/debian_version` 11.11 -> 13.7. `apt-get -s` of the repacked 6.0 set in an arm64 chroot of the 5.1.33 root: exit 100, unmet dependencies for 24 packages (ble-http-transport, bluez-tools-ui, fluent-bit, jq, libcurlpp, libjq1, libpam-usermapper, libsodiumpp, libubnt, libuled, systemd-networkd-fallbacker, ubnd, ubnt-disk-smart-mon, ubnt-rpsd, ubnt-sfp-handler, ubnt-tools, ubnt-ucp4cpp, ubntnas, ucore-setup-listener, ui-snmp, uled-control, uos, uos-agent, ustate-exporter) | Breaks us. Guarded in this PR; 6.0 itself needs a Debian 13 guest (not done here) |
| 2 | `update-unifi.sh` follows `firmware-latest` (now 6.0.11) and stamps `/usr/lib/version` even when apt installed nothing (its `apt-get ... \|\| echo NOTE` swallows the failure) | API response, script lines before this PR | Fixed: `OS_TRACK`, Debian guard, version stamped only if unifi-core reached the firmware's version |
| 3 | `install-protect-baremetal.sh` Phase 4 also takes `firmware-latest`, copies its version file, then fails in Phase 5 | same | Fixed: same track default and Debian guard, before the version file is written |
| 4 | New `ufcd.service` (UI fan control, package `ustd`): `WantedBy=local-fs.target`, `Wants/After=usdbd.service`, `Restart=always`; on a VM it has no fans to drive and can only fail and be restarted (the binary itself was not run) | unit file in 6.0 `ustd` | Masked in both installers' lists (harmless on 5.x) |
| 5 | Storage Patch A anchor gone: 6.0's unifi-core never calls `ustorage space inspect`, so the patch script would raise its anchor alert (journal error + Pushover) on every unifi-core start | real 6.0.11 `service.js`: 0 matches | Fixed: recognised as not needed, exits 0 quietly; 5.1 path unchanged |
| 6 | App debs are per Debian base: `uos-deb11-arm64` and `uos-deb13-arm64` (no deb12) | API queries for unifi-protect, unifi-access, ai-feature-console, ms, msr, ds, protect-verify | Fixed: platform derived from `/etc/os-release` (11 -> deb11, so unchanged today) |
| 7 | The console UI's Update reaches `ubntnas`: `ubnt-systool fwupdate` runs `ubntnas system upgrade <file> -f --no-reboot` whenever `ubntnas` is on PATH (it is), and `ubntnas` writes a real UNVR's boot layout (flash partitions, the eMMC's kernel and root partitions, the uboot environment). Not new in 6.0, but 6.0.11 being the API's latest makes the console's own update offer likely. Correction (2026-10-25): the `/dev/sda*` paths in its strings belong to another board, not the UNVR, and on the VM it stops at the missing `/proc/ubnthal` before writing anything; the risk was the 6.0 updater it runs first, not the recording disks. See "How a real UNVR upgrades in place" | The branch of `ubnt-systool` `do_fwupdate` that calls `ubntnas`, identical in 5.1.33 and 6.0.11; found by the operator's review; `ubntnas` device table and control flow from its disassembly | Fixed: `ubntnas` guard (`vm/wrappers/rootfs/usr/bin/ubntnas`), installed by `install-shims.sh` with `dpkg-divert` |

Also fixed here, pre-existing but in the same path: the `--sync-os` version
diff counted the firmware's bundled `unifi-protect` and `ai-feature-*`
packages, which the script never installs. On a guest with Protect 7.3.70 a
sync of the release already installed therefore listed phantom downgrades
(`unifi-protect 7.3.70 -> 7.1.87`, `ai-feature-controller 2.1.5 -> 2.0.17`)
and stopped and restarted the whole stack for nothing. And `--access`
compared `v4.3.22+12152` (API) with `4.3.22+12152` (dpkg), so it reinstalled
Access on every run.

Everything else checked is unchanged or changed harmlessly; details follow.

## Comparison

### Packages

| Item | 5.1.33 | 6.0.11 | Verdict |
|------|--------|--------|---------|
| Debian base | 11.11 bullseye | 13.7 trixie, merged /usr (`bin`, `sbin`, `lib` are links) | changed, breaks us (item 1) |
| Packages in the image | 437 | 429 | - |
| Ubiquiti packages (`@ui.com`/`@ubnt.com`) | 50 | 51 | 3 new, 2 removed, 30 changed, 18 same version |
| New | - | `bluez-tools-ui` 5.82.1 (`bccmd`, `hciattach_ui`), `diskclass` 1.1.0 ("HDD/SSD classifier"; no caller found in units, udev rules, `/usr/bin`, `/usr/sbin`, ustd or unifi-core), `fluent-bit` 5.0.9 (audit log shipper) | changed, harmless; they are repacked and installed like the rest |
| Removed | `node20` 20.19.5, `openssh-server-keygen` 0.3 | - | changed, harmless (nothing in the repo uses node20) |
| Same version, rebuilt | e.g. 1.6~ubnt: `jq` libc6 >= 2.17 -> >= 2.34, `libjq1` libc6 >= 2.29 -> >= 2.39 | | the version string hides a trixie rebuild; covered by item 1 |
| Key versions | unifi-core 5.1.132, ustd 5.1.18, ustate-exporter 1.27.5, ubnt-tools 5.1.11, uos 5.1.5, ulp-go 1.13.11, bundled Protect 7.1.87 | unifi-core 6.0.123, ustd 6.0.9, ustate-exporter 1.32.0, ubnt-tools 6.0.20, uos 6.0.4, ulp-go 1.14.7, bundled Protect 7.2.105 | changed; bundled Protect is never installed (the script installs Protect from the API) |
| `unifi-email-templates-all` | 1.6.0-rc.12 | 1.4.0-rc.4 (a downgrade) | harmless, the script passes `--allow-downgrades` |
| Kernel packages the script excludes | `linux-image-4.19.152-alpine-unvr` 4.19.152, `unvr-initramfs` 2.0 | identical | unchanged; the name patterns still match |
| Postgres | pgdg `postgresql-14` 14.24 and `postgresql-16` 16.15 (`pgdg11` builds) | the same majors and minors, `pgdg13` builds | unchanged major. Protect 7.3.70 declares `postgresql-14` on both platforms, so Protect's database is **not** migrated. No unit or cluster definition uses 16 in either image |
| Postgres clusters (`/etc/default/postgresql/`) | 14-main (5432), 14-protect (5433) | + **14-apps** (5434, from unifi-core 6.0) | changed, harmless for the VM; not added to `critical-services-watch.sh` until a booted 6.0 shows when it runs |
| Node | node24 24.8.0 (+ node20) | node24 24.15.0 | changed, harmless; Protect needs node24 >= 24.8.0, `ustated-shim` runs on 24.15.0 (spot check below) |
| systemd, python, mdadm, smartmontools | 247, 3.9, 4.1, 7.2 | 257, 3.13, 4.4 (moved to `/usr/sbin`), 7.4 | Debian packages, not installed by `--sync-os`; matter only for a Debian 13 guest |
| `unvr-al324-base-files` | `dpkg-repack` fails (conffile `/etc/logrotate.d/syslog-ng-base-files` not in the package) | same failure | unchanged; the script already warns and continues |

### systemd units

| Unit | Change in 6.0.11 | Verdict |
|------|------------------|---------|
| `usd` | `TimeoutSec` 600 -> 900. Anchors unchanged: `DefaultDependencies=no`, `After=local-fs-pre.target usdbd.service uhwd.service`, `Before=local-fs.target`, `WantedBy=local-fs.target` | unchanged for us. usd's slot exists exactly as `provision-storage.service` copies it; its 600 s start limit is a separate, deliberate choice |
| `usdbd`, `ustated`, `uhwd`, `uscsi-disk-ready` | identical | unchanged |
| `ufcd` | new, `WantedBy=local-fs.target`, wants `usdbd` | needs a change in `update-unifi.sh` and `install-protect-baremetal.sh` (done: masked) |
| `ms`, `msr`, `msp`, `mst` | the firmware-bundled builds' unit files are identical. The guest's media services come from the API instead (5.1.317, the same version for deb11 and deb13; their Maintainer has no e-mail address, so `--sync-os` never repacks them) | unchanged; the unit names the `10-wait-for-volume1.conf` drop-ins attach to are the same |
| `unifi-core` | `Wants=` adds `fluent-bit-audit.service`; `Sockets=audit-shipper.socket`; `$UNIFI_CORE_HEAP_OPTS`; `KillMode=control-group`; the 5.1.33 drop-in `unifi-core.service.d/memory.conf` (MemoryMin 200M, MemoryLow 300M, MemoryHigh 1024M, MemoryMax 1536M, MemorySwapMax 200M) is gone and the unit now sets `MemoryMax=1536M`, `MemorySwapMax=0`, `OOMScoreAdjust=-900`: in effect MemoryHigh/Low/Min are dropped and swap goes to 0 | changed, harmless; only matters on a Debian 13 guest (the socket's user `audit-shipper` must exist there) |
| `ulp-go` | `Restart=always`, memory limits | changed, harmless |
| `postgresql@14-protect` | only `memory-limits.conf` values | unchanged for us; `10-assert-datadir.conf` still applies, `pg_conftool` comes from the same postgresql-common 293 |
| `local-fs` ordering | `/etc/.../local-fs.target.wants` gains only `ufcd`; `local-fs-pre.target.wants` (uscsi-reset-wipe, uscsi-rescan, uscsi-disk-ready) unchanged. The vendor `/usr/lib/systemd/system/local-fs.target.wants` gains systemd 257's `tmp.mount` and `run-lock.mount` | unchanged for the current guest once ufcd is masked. On a Debian 13 guest `/tmp` becomes a tmpfs; check nothing of ours keeps large files there |
| New elsewhere | `fluent-bit-audit`, `audit-shipper.socket`, `unifi-audit-protect` (`chattr +a /data/audit`), `unifi-audit-cleanup.timer`, `unifi-protect-permission-repair` (bundled Protect), systemd 257's `capsule@`, oomd slice drop-ins | changed, harmless for the current VM |
| Boot hook `55-unmask.py` | now `unmask --no-reload` + one `daemon-reload`; the list it unmasks (`unifi-protect`, `postgresql@14-protect`, `uid-agent`, `smbd` ...) is identical and holds nothing we mask | unchanged |
| Boot hook `99-replay-late-mount` (new) | runs `ustorage space replay-late-mount` to replay usd's mount hooks | harmless: our `ustorage` exits 0 silently on unknown verbs, and `provision-storage.sh` already makes `/srv` |

### Paths and fields our shims and patches use

| What | 6.0.11 | Verdict |
|------|--------|---------|
| `ubnt-tools` (shim at `/sbin/ubnt-tools`) | still installed at `/sbin/ubnt-tools` by `ubnt-tools`. Callers are the same files with the same subcommands: `id` (unifi-core, pre-start hooks, ms pre-start, AI controller, `unifi-protect-tmpfs`, board-info cache hook) and `uuid` (`ubnt-systool`), and the bundled `unifi-protect.service` reads `board.sysid` in both. Fields read: `board.sysid`, `board.shortname`, `board.bom`. unifi-core's EEPROM dump (`ubnt-tools id <file>`, behind a predicate) is the same code as in 5.1.33; the shim writes no file there, so if it runs it logs "Failed to read EEPROM" exactly as today | unchanged |
| `uled-ctrl`, `smartctl` | `/usr/bin/uled-ctrl`, `/usr/sbin/smartctl` | unchanged |
| `/usr/bin/ustorage` | still owned by `ustd`, so a sync still overwrites it and `install-storage.sh` re-lays it. Verbs unifi-core 6.0 calls: `config hotspare`, `config prefer`, `rwfs check`, `rwfs migrate`, `space nuke`, `disk clean <slot>` and `disk inspect <slot>` (both for the per-disk erase, as in 5.1.33), and new `worm check`. `space inspect` is no longer called | `worm check` is gated by `features.storage.supportsWorm`, set only for an enterprise NAS model, not UNVR. Still answered now (done), in the real 6.0 output shape. Pre-existing, not 6.0: the shim has no `disk clean`, so the UI's per-disk erase does nothing on the VM while unifi-core logs success |
| unifi-core storage patch | Patch A anchor `iwe={space:e,disks:[],sdcards:[]};` and the `"ustorage",["space","inspect"]` call: 0 matches. Disks come from the gRPC store (`DiskState` stream -> `getV1StorageState()` / `getTransformedDisks()`), which `ustated-shim` feeds. Exec helper renamed `Q` -> `q` | needs a change in `unifi-core-storage-patch.sh` and `update-unifi.sh --verify` (done: "not needed") |
| storage gRPC API | `@ubnt/unifi-protobufs` 0.115.0 -> 0.143.0; still `storage/v1` and `v2` (no v3), same six v2 RPCs, still `127.0.0.1:11052`; only additive enum values (`DISK_RISK_REASON_INVESTIGATION_NEEDED`, `SPACE_ISSUE_TYPE_RAID_BAD_BLOCKS`, `CACHE_POLICY_LVM_RAND`); `accessory/v1` identical; grpc-js 1.14.1 -> 1.14.3 | unchanged; spot-checked below |
| UNVR model entry in unifi-core | storage still `{id:1,type:"raid",mountPoint:"/srv",path:"/dev/md3"}` (the `mdadm` wrapper's premise); adds `nonPrivateLocalDiscovery`, `discoverDevices` and a `webrtcWorker` run as a systemd unit | unchanged for the storage path |
| anonymous device id | `ubnt-systool do_anonid` unchanged: a valid `/var/run/anonymous_device_id` wins; unifi-core still calls `ubnt-systool anonid`; `configPath` still `/data/unifi-core/config` (settings.yaml) | unchanged; spot-checked below |
| ms/msr/msp/mst drop-ins, `postgresql@14-protect` drop-in | unit names and files unchanged | unchanged |
| `ustated` shim service | `ustated.service` identical; `node24` still `/usr/bin/node24` | unchanged |

### New hardware queries and checks a VM could fail

- `ufcd` (fan control, `Restart=always`): no fans to drive on a VM, so it can
  only fail and be restarted (until systemd's start limit, at best). Masked
  by this PR.
- `ubnt-systool network-fec` (FEC on the SFP ports) is newly called by
  unifi-core. Expect at most a logged error on a VM; check on a Debian 13 guest.
- `diskclass`: shipped, no caller in the image.
- `bluez-tools-ui`, `fluent-bit-audit`, `unifi-audit-protect`, systemd-oomd
  drop-ins: software only, nothing UNVR-specific. `chattr +a` needs ext4 on
  `/data`, which the VM has.
- WORM checks: gated off for UNVR (above).
- Nothing else new in the boot hooks: `bootup-top` gains `03-neigh-gc-thresh.sh`
  and `60-fix-cron-permission`, `bootup-bottom` gains `99-replay-late-mount`.

### The update mechanism

- **API**: `firmware-latest` JSON for 6.0.11 has the same fields the script
  reads (`version`, `_links.data.href`, `sha256_checksum`, `file_size`), plus
  `version_major/minor/patch`. `/api/firmware` lists builds unordered, 25 per
  page by default (52 UNVR release builds exist), so the new track lookup
  passes `limit=500`, sorts numerically and warns if the page fills.
- **Version strings**: `/usr/lib/version` is
  `UNVR4.al324.v6.0.11.dd9ab55.260930.0750`, the API says `v6.0.11+dd9ab55`.
  The old `--check` compared the raw strings, so it always showed an OS update.
  Now both are reduced to `6.0.11`.
- **Firmware container**: same Ubiquiti header and blob layout as 5.1.33, one
  zstd squashfs (v4.0) per image at offset 15241827 (5.1.33) and 15760846
  (6.0.11). `find -name squashfs-root | head -1` still finds the right tree;
  `dpkg-query --admindir` and `dpkg-repack --root` work on the trixie root.
- **binwalk** (observation, no change): with Ubuntu 24.04's packaged binwalk
  2.3.4, which pulls in 7z, `binwalk -e` also inflated dozens of false-positive
  LZMA blobs and passed 11 GB per image before it was stopped. The same blobs
  are in 5.1.33, which the guest synced without filling its root disk, so
  something in the guest's tool set differs.
  Worth knowing before anyone changes binwalk on the guest: `/opt` is on the
  small root disk. The squashfs was unpacked here with
  `unsquashfs -o <offset>`, which gives the same tree.

## Spot checks under qemu-user

All in arm64 chroots of the unpacked images (qemu-aarch64 8.2.2 via binfmt), no
boot:

- **`--sync-os` onto bullseye**: the 6.0 set repacked with `dpkg-repack` (50 of
  51; `unvr-al324-base-files` fails as it does for 5.1.33), the script's
  exclusions applied (kernel, initramfs, Protect, AI, Access), then
  `apt-get install -s --allow-downgrades --no-install-recommends` inside the
  5.1.33 root: exit 100, "Unable to correct problems", 24 packages unmet (item 1).
- **`ustated-shim.js` on 6.0's node24 24.15.0 and 6.0's grpc-js/protobufs**:
  starts, registers storage v1 + v2 and accessory v1 on :11052. A client built
  from 6.0's own `api_grpc_pb.js` received and decoded a first message from all
  six v2 streams (DiskState, SpaceState, StorageSettings, CacheSlotState,
  SDCardState, FlashState).
- **`ustorage` (the VM shim) on 6.0's python 3.13**: `disk inspect`,
  `space inspect`, `config show`, `rwfs check` return valid JSON. The real 6.0
  `ustorage worm check` printed
  `{"counts": {"compliance": 0, "enterprise": 0}, "has_worm": false, "modes": []}`
  (and the `--details` form); the shim now prints the same.
- **Anonymous id**: `seed-anonid.sh` with the repo's `ubnt-tools` shim derived and
  seeded an id; the real 6.0 `ubnt-systool anonid` returned it unchanged.
- **Storage patch** on copies of the real bundles: 5.1.33 patched once; 6.0.11
  before this PR raised `ALERT: Patch A anchor not found (count=0)`, after it
  "not needed", file untouched.

## What the code changes cover

All guarded so a Debian 11 / 5.1.33 guest behaves as before, except where the
old behaviour was the bug:

- `vm/installers/update-unifi.sh`
  - `OS_TRACK` (`--os-track`): `5`, `5.1`, `5.1.33` or `latest`. Default: the
    major built on the guest's Debian release (bullseye -> 5, trixie -> 6,
    unknown -> latest). On the current guest it resolves to 5.1.33, so
    `--check` reads "up to date" and names 6.0.11 as outside the track. A
    track asks `firmware-latest` with the version filters first (the
    server's own pick, staged rollouts included); the sorted `/api/firmware`
    listing is the fallback, ties broken by creation time. A non-JSON API
    answer is a clear error. A missing or bad track is fatal only for
    `--sync-os` and `--all`; `--check`, `--protect` and `--access` carry on.
  - `--sync-os` and `--all` refuse a firmware outside the line built on the
    guest's Debian before the pre-update snapshot and the download
    (`fw_line_matches_debian`).
  - `--check` warns when Protect or Access is newer on `uos-deb13-arm64`
    than on deb11: the deadline signal for the Debian 13 move.
  - `--check` warns when the selected firmware is not the line built on the
    guest's Debian (e.g. `OS_TRACK=6` or `latest` on bullseye) and when a
    pinned release is older than the installed one (`--allow-downgrades`
    would apply it).
  - Debian guard in `sync_os_packages`, right after extraction and before any
    service is stopped, as the backstop for the line check above: refuses a
    firmware whose `VERSION_CODENAME` differs from the guest's, cleans the
    work dir, exits non-zero.
  - `/usr/lib/version` is copied only when every package offered to apt is
    `ii` at the firmware's version (excluded packages and failed repacks do
    not count); otherwise an ERROR naming each package, the stack is still
    re-masked, re-shimmed and restarted as before, and the script exits 1
    after cleanup. With `--all` the Protect and Access upgrades are skipped in
    that case.
  - The version diff skips the firmware's bundled app packages
    (`unifi-protect`, `ai-feature-*`, `unifi-access`), which the script never
    installs; this removes the phantom-change restart described above.
  - `DEB_PLATFORM` from `/etc/os-release`: 13 -> `uos-deb13-arm64`, anything
    else -> `uos-deb11-arm64` (deb12 is not published); overridable.
  - `ufcd` added to the mask loop; `--verify` checks it when the unit exists and
    accepts "Patch A not needed" on a bundle with neither the
    `ustorage space inspect` call nor its snapshot.
  - `--check` compares OS versions as X.Y.Z, and app versions without the
    API's leading `v`; `--access` likewise, so it no longer reinstalls
    Access on every run.
  - `--verify` checks the `ubntnas` guard; `--help` prints the whole header,
    usage and `OS_TRACK` included.
  - The helpers sit above a "sourced: return" guard so tests can load them.
- `vm/installers/install-protect-baremetal.sh`: the same `OS_TRACK` default for
  Phase 4 (`FW_URL` still wins), the Debian guard before `/usr/lib/version` is
  written (it also deletes the refused `fwupdate.bin`, which Phase 4 would
  otherwise reuse without asking the API again), `fw_api_href` picks the
  newest of a listing, `DEB_PLATFORM` for the Protect and AI queries, `ufcd`
  masked. The firmware-bundled `AIFC_STABLE_URL` pin stays deb11 (that path is
  documented as untested).
- `vm/storage/rootfs/usr/local/bin/unifi-core-storage-patch.sh`: exits 0 with
  "not needed" only when the bundle has neither a `"ustorage",["space","inspect"`
  call (with any arguments) nor the snapshot's `disks:[],sdcards:[]}` shape.
  A 5.1 bundle keeps the patch and the drift alert. `SVC`/`PUSH_CONF` can be
  set for tests.
- `vm/storage/rootfs/usr/bin/ustorage`: `worm check [--details]`.
- `vm/wrappers/rootfs/usr/bin/ubntnas` (new) and `vm/installers/install-shims.sh`:
  the guard refuses `system upgrade` (also behind a leading flag), prints the
  reason `ubnt-systool` shows in the UI, logs it, and passes everything else
  to the real binary. `install-shims.sh` diverts the packaged binary to
  `/usr/bin/ubntnas.real` with `dpkg-divert`, so a `--sync-os` reinstall of
  the `ubntnas` package lands there and never replaces the guard.
- `vm/tests/test_unifi_os6_compat.sh`: 91 stubbed checks (no root, no VM, no
  network; Linux, and macOS with python3 and jq, where the dpkg-only checks
  are skipped), covering the helpers, the guard and version-stamp wiring,
  the installer's track block and guard (run against fixtures), the patch
  script on 5.1, 6.0 and drifted bundles, ustorage, and the `ubntnas` guard. It first checks statically
  that the update script has its sourced-return guard and refuses to source
  it otherwise, so against the code before this PR it stops at that check.
  With `FW_ROOT_51`/`FW_ROOT_60` pointing at unpacked images it adds 4 checks
  against the real firmware.

Not changed, on purpose: `ustated-shim.js`, the `ubnt-tools` and smartctl
parts of `install-shims.sh`, `seed-anonid.sh`, the ms/msr/msp/mst and postgres drop-ins,
`provision-storage.service` (all verified unchanged or compatible above), and
`critical-services-watch.sh` (14-apps is left out until a booted 6.0 shows it
always runs; adding it now would alert on 5.1.33 where it does not exist).

## Route to 6.0 (proposal, untested)

6.0 needs the guest on Debian 13 first. Two ways were weighed. **Decided
(operator, in review): option 2**, a fresh trixie guest built alongside the
live one. Option 1 stays below for the record; it is not for the production
NVR, whose array is outside the snapshot.

1. **In-place** (keeps `/data`: identity, databases, the anonid store):
   `apt full-upgrade` bullseye -> bookworm -> trixie, switching the pgdg and
   nginx.org sources at each step (`fix_apt_ubiquiti_sources.sh` already
   follows `VERSION_CODENAME`). The APT pin (`Pin-Priority: -1`) stops apt
   from *upgrading* the Ubiquiti packages but not from *removing* one whose
   dependencies break, so `apt-mark hold` them for the dist-upgrades and
   unhold afterwards (holds break `uos runnable`, so they must not stay).
   Re-lay the `mdadm` wrapper if mdadm was upgraded (trixie moves it to
   `/usr/sbin/mdadm`; the wrapper is not a dpkg diversion) and run
   `install-shims.sh` for smartctl. Do not run `update-unifi.sh` at the
   bookworm stop. Then `OS_TRACK=6 update-unifi.sh --sync-os`: the guard
   passes. The apps need one more step: Protect 7.3.70, ms/msr/msp/mst
   5.1.317, ds 7.3.6 and the AI packages have the same versions on deb11 and
   deb13 (Protect's two control files are identical), so `upgrade_protect`
   says "Already at" and keeps the deb11 builds. Reinstall the deb13 builds
   by hand (`apt-get install --reinstall` of each downloaded deb) and record
   whether the deb11 ones ran at all. Postgres stays 14 (same on-disk
   format); check every cluster's collation, since glibc goes from 2.31 to
   2.41 and text indexes in a glibc locale other than C would need a
   REINDEX. UniFi's own `pg-cluster-upgrade` creates clusters with
   `--locale=C`; the 14-main cluster made by the installer's
   `apt-get install postgresql-14` took the guest's default locale. systemd
   257 also makes `/tmp` a tmpfs.
2. **Fresh Debian 13 guest** + restore of the UniFi OS backup. Needs
   `install-protect-baremetal.sh` ported to trixie (its bullseye check, Phase 1
   package list, jq/libjq1 handling) and is a larger change than this PR.

## How a real UNVR upgrades in place, and what that means here

Added 2026-10-25 to answer three questions from the operator: what the
device's own upgrade writes, whether the VM could upgrade the same way, and
what 6.0 does to the data array that a snapshot would not undo. Everything
here comes from the 5.1.33 and 6.0.11 images unless a line is labelled
otherwise. Method: the firmware container parsed by its section headers; the
initramfs scripts, u-boot environment and hooks read as text; `ubntnas` and
the bundled updater (both stripped Go binaries) disassembled with function
names recovered from their Go symbol tables; and the bundled updater's own dry
run (`-d`), run as `nobody` in a chroot with no network. Nothing was run
against a device or a disk.

### 1. What the device's own upgrade writes

**The firmware file.** `fwupdate.bin` is a `UBNT` header followed by
`FILE`/`PART` sections, each with a name, a size, its data and a CRC:

| Section | 5.1.33 | 6.0.11 | Where it goes |
|---------|--------|--------|---------------|
| `uboot` | 1,395,740 B | identical (same SHA-256 `c587b790...`) | Flash `/dev/mtdblock0`, only if it differs from what is there; then the u-boot environment (`mtdblock1`, `mtdblock2`) is cleared. Identical here, so a 5.1.33 -> 6.0.11 upgrade skips it |
| `kernel` | uImage, 4.19.152-alpine-unvr, 13.8 MB | same kernel version, rebuilt, 14.4 MB | eMMC units: file `uImage` on the kernel partition, the old one renamed `uImage.bkp`. NAND units: `/dev/mtd9` erased and rewritten |
| `rootfs` | zstd squashfs, 768 MB | 818 MB | eMMC units: file `rootfs.new` on the root partition (`/boot/firmware`). NAND units: `/dev/mtd10` erased and rewritten |
| `dpkg-status`, `trixie-keyring` | absent | new | Not written anywhere; the updater reads them to fetch Debian 13 builds of installed apps (below) |
| `updater` | Go binary `uof-updater` 1.0.36 | 1.0.44 | Extracted to a tmpfs and run before and after the image writes |

**Where a real UNVR keeps its system.** There are two hardware variants.
6.0's initramfs (`product-override`, `ui-boot-emmc`, `ui-boot-nand`) and the
device table inside `ubntnas` agree:

| | eMMC units (sysid `ea1a`, "NVR" in unifi-core's device list; `ea20`, UNVR Pro) | NAND units (sysid `ea16`, the UNVR / UNVR-4; "UNVR without eMMC" in the initramfs) |
|---|---|---|
| u-boot, its environment, `/config` (flags) | flash `mtdblock0`, `mtdblock1`+`2`, `mtdblock6` | same |
| Kernel | `/dev/boot1`, ext4 (128 MiB): `uImage`, `uImage.bkp` | `/dev/mtd9`, raw |
| Root image | `/dev/boot2`, ext4 (2 GiB) at `/boot/firmware`: `rootfs`, `rootfs.bkp`, transiently `rootfs.new` | `/dev/mtd10`, raw; copied into a RAM disk at boot |
| `/data` | `/dev/boot3` (4 GiB) | inside the overlay |
| `/var/log` | `/dev/boot4` (4 GiB) | inside the overlay |
| Overlay upper (`/mnt/.rwfs`; `/persistent` lives in it) | `/dev/boot5` (about 4.5 GiB) | internal USB stick `/dev/sdq`, or after the "flash storage migration" `md1`, a RAID1 over every data disk's partition 3 |

`/dev/boot` is the eMMC. It sits behind USB (u-boot loads the kernel with
`usb start; ext4load usb 0`, and `ubntnas` carries a SCSI-passthrough eMMC
driver), so it is not an `mmcblk` device. The kernel names it `boot*`;
Ubiquiti's udev rule only adds by-path and by-partlabel links for it. No
UNVR entry in `ubntnas` uses `mmcblk`, `by-partlabel` or `/dev/sd*`: those
belong to other boards (`/dev/sda1`, `sda2`, `sda5`, `sda7` to sysid `e990`,
the CloudKey Enterprise). The VM's `ubnt-tools` shim reports `ea16`, the
UNVR. If that was copied from the operator's unit, the unit is a NAND one;
only the unit can confirm it (checks below).

**Slots.** There are no A/B partitions. The backup is one release deep, by
file name: u-boot's `multiboot` tries `uImage` with `root=rootfs`, then
`uImage.bkp` with `root=rootfs.bkp`, then a raw kernel copy past the last
eMMC partition, then the recovery kernel in SPI flash. It falls back only
when u-boot cannot load or start a kernel; no boot counter was found, so a
6.0 that boots but misbehaves stays booted. NAND units have no backup copy:
the flash is erased and rewritten in place.

**What `ubntnas system upgrade <file> -f --no-reboot` does** (6.0.11 binary),
in order:

1. Reads `systemid` from `/proc/ubnthal/system.info`. If that fails, it stops.
2. Validates the file: platform match, `/sbin/fwupdate -c` (signature), and
   no downgrade unless `-f`. `ubnt-systool` passes `-f` unless it is called
   with `--no-downgrade`, which unifi-core does not pass.
3. Takes `/run/system.lock` and runs the `upgrade-top` hooks
   (`ubnt-dpkg-status` records the installed apps).
4. Extracts the new firmware's updater to a tmpfs and runs
   `updater -t top -p <file>`. This is skipped on a forced downgrade or when
   the updater cannot be extracted.
5. Writes the images for its sysid, in this order: u-boot (only if it
   differs), kernel, rootfs. Preloader, ATF, QCA and dtbo steps exist for
   other boards.
   - eMMC kernel: the kernel partition is mounted at `/tmp/.kernel`,
     `uImage` becomes `uImage.bkp`, and the new `uImage` is written.
   - eMMC rootfs: `/boot/firmware` is remounted read-write. `losetup`
     reports which image the system booted from. If that is `rootfs`, it
     deletes `rootfs.bkp`; if it is `rootfs.bkp`, it renames it to `rootfs`.
     Any other backing file fails ("unrecognized type of device") before
     anything is written. Then it writes `rootfs.new`.
   - Why the delete (my arithmetic, not from the code): the 2 GiB partition
     cannot hold the running image, an older backup of similar size and the
     new one, which is 768 + about 768 + 818 MB for 5.1.33 -> 6.0.11.
   - NAND units: the kernel and rootfs flash are erased and rewritten.
6. Mounts the config flash at `/tmp/.config` and creates `.upgrade-bootup`.
7. Runs `updater -t bottom` and the `upgrade-bottom` hooks, still in the old
   system. Both are deferred, so they also run after a failed write; the
   hooks get the result in `UPGRADE_SUCCESS`. `ubnt-systool` then reboots.
8. On the next boot the initramfs loop-mounts `rootfs.new` as a check, then
   renames `rootfs` to `rootfs.bkp` and `rootfs.new` to `rootfs`. Because the
   version changed, it deletes from the overlay upper every copy of `bin`,
   `sbin`, `lib`, `usr`, a list of `/etc` entries (among them `sshd_config`,
   `nginx`, `sysctl.d`, `udev`, `pam.d`, `etc/postgresql/14/protect`), every
   non-Ubiquiti file under `/etc/apt`, and every file under `/var` except
   `/var/log`. Apps come back on first boot through `ubnt-dpkg-rescue` from
   the cache in `/persistent/dpkg/<codename>`.

So an upgrade erases: the older backup image and kernel, the u-boot
environment (only when u-boot changes, not for 5.1.33 -> 6.0.11), and the
upper-layer copies listed in step 8. On NAND units the updater's
`AutoUNVR4USBMigrate` can also empty `/var/log` when the overlay only fits
its new home without the logs. The upgrade itself writes nothing to the
data disks on either variant. The exception is the flash storage migration
on NAND units, which the next boot carries out (section 3).

**What the updater runs for 5.1.33 -> 6.0.11.** From its dry run
(`updater -t top|bottom -d -v UNVR4.al324.v5.1.33.44ce47b.260909.0025`),
with each step's effect read from the binary. All steps older than 6.0 are
skipped ("Current version is bigger").

- Top: `CleanDirectSystemdLinks` (only on a bullseye root: deletes
  `/etc/systemd/system/*.service` symlinks that point at the same name
  under `/lib/systemd/system/`), `PreStageTrixieCache` (only on a bullseye
  root: reads `dpkg-status` and `trixie-keyring` from the file and downloads
  the Debian 13 builds of the installed apps into `/persistent/dpkg/trixie`;
  its log text says a failed download blocks the upgrade), `Cn10kEnasBoot`
  (sysid `ea64` only).
- Bottom: `AutoUNVR4USBMigrate` (sysid `ea16` only, section 3), `CheckRWFS`
  (touches `/etc/passwd` and `/etc/group`), `RemoveUnusedSrvCondiction`
  (removes Protect's `condition-srv.conf` drop-in when `/ssd1` is a mount),
  `CleanupBullseyeDir` (deletes `/persistent/dpkg/bullseye`),
  `UpdateUNVRINSRecovery` (sysid `ea61` only).

One consequence: the device's own 6.0 upgrade wants Ubiquiti's package
servers reachable. An offline UNVR, or an isolated clone, would stop at
`PreStageTrixieCache`. This comes from the log strings; the code path was
not traced end to end.

**On this VM.**

- `ubntnas system upgrade` stops at step 1: the VM has no ubnthal module, so
  `/proc/ubnthal/system.info` does not exist. The disassembly shows that
  error returning before the lock, the hooks, the updater or any write.
- The 5.1.33 `ubntnas` the VM runs today does the same: it reads
  `systemid=` first and returns on failure (checked in its disassembly).
- Suppose it ever got a sysid (`ea16` from the shim, or `ea20` with
  `DEVICE=UNVR_PRO`). Both point at `mtd` and `/dev/boot*` devices the VM
  does not have, so the image writes would fail. The 6.0 updater would
  still run on the VM's bullseye root, with its network access: the top
  stage before the writes, and the bottom stage and hooks on exit. The top
  stage includes `PreStageTrixieCache`, contacting Ubiquiti's package
  servers from the live console, and `CleanDirectSystemdLinks`, editing
  `/etc/systemd/system`. The updater does not need `/proc/ubnthal`: it
  falls back to `ubnt-tools id`, so on the VM it sees `ea16`, and
  `AutoUNVR4USBMigrate` passes its board check. Read from the code, not
  run: what then stops that step on the VM is the missing `/mnt/.rwfs` and
  config flash.
- No UNVR sysid targets `/dev/sd*`, so breaking item 7 overstated the risk
  to the recording disks (corrected there). The guard stays: it costs
  nothing, gives a clear refusal, and keeps the updater from running at all.
- `ubntnas system reset` (open question): it stops at the same first step.
  On a real UNVR it runs the reset-top and reset-bottom hooks and writes
  `/config/.reset-to-defaults`. With the format option, the next boot wipes
  the data disks in two places:
  - The initramfs. On NAND units it zeroes the start of each data
    partition 5 and writes a new GPT on it. On eMMC units it does that to
    every whole `/dev/sd[a-p]` disk.
  - `uscsi-reset-wipe.service`, which wipes the slot disks.

  On the VM the first never runs, because the VM boots Debian's initramfs.
  The second ships enabled in the firmware's `ustd` package, which the VM
  installs (`ufcd` and `usd` come from it). Its built-in docstrings say it
  looks for the config partition in `/proc/mtd`, which the VM lacks, so it
  should do nothing. That is inferred from a compiled binary, and whether
  the unit is enabled on the VM was not checked (`systemctl is-enabled
  uscsi-reset-wipe`). So a reset looks inert here today, for two
  independent reasons.

  Recommended, not done in this doc-only commit: add `uscsi-reset-wipe` to
  the installers' mask lists, since it is the one Ubiquiti unit on the VM
  whose job is to wipe the recording disks. Also add `system reset` to the
  guard, for symmetry.

### 2. A device-style in-place path for the VM (design only)

The device swaps a read-only image under a writable overlay. The VM is an
ordinary read-write Debian install with the Ubiquiti packages repacked into
it by dpkg. "Swap the rootfs" therefore means converting the VM to the
device's model once; after that, every upgrade is a file swap. That is
option 3 next to the two in "Route to 6.0". Its draw is that apt and Debian
dependency resolution leave the OS path entirely, because the firmware's
squashfs already is a complete Debian 13 root with all of UniFi OS in it.
Apps such as Access are installed on top, as on the device.

**Layout.**

- vda keeps the ESP and today's root filesystem. It stops being `/` and
  serves `/data`, `/persistent` and `/var/log` by bind mounts.
- A new small virtio disk (qcow2, 8 GiB, listed in `STORAGE_IMAGES` so
  `snapshot.sh` covers it) is laid out like the eMMC:
  - p1 `kernel`: a generic arm64 kernel and initrd, plus `.bkp`. The
    firmware's uImage is built for the AL324 SoC and cannot boot a QEMU
    `virt` machine.
  - p2 `root`: `rootfs`, `rootfs.bkp`, `rootfs.new`, which are the
    firmware's squashfs byte for byte.
  - p3 `overlay`: the upper and work directories.
- `/ssd1`, md0 swap and md3 at `/volume1` stay as they are, mounted by the
  guest's own fstab and `provision-storage`.
- Boot: EFI on vda loads the kernel and initrd from p1. Our own initramfs
  hook, about 80 lines, does what `ui-boot-emmc` does:
  - if `rootfs.new` loop-mounts, rename `rootfs` to `rootfs.bkp` and
    `rootfs.new` to `rootfs`;
  - mount the squashfs under the overlay;
  - bind the vda paths;
  - on a version change, clear upper copies of vendor paths, except an
    allow-list of our shims.

  Ubiquiti's scripts are a model, not something to copy into this repo.
- The image only carries modules for the 4.19 AL324 kernel, so the guest
  kernel's modules come from outside it (the upper, or a modules squashfs
  next to `rootfs`) and must match p1.

**One-time conversion** (on a clone first, isolated per the test plan):

1. `snapshot.sh create` (vda and `STORAGE_IMAGES`; the array is not covered,
   see section 3).
2. Build the boot disk. Verify the firmware's SHA-256 against the API, cut
   the `rootfs` section out at its header offset, and check it with
   `unsquashfs -s`.
3. Decide where today's root-only state lives: `/data` (identity, the 14-main
   and 14-protect clusters, unifi-core), `/persistent`,
   `/etc/default/device`, `/etc/default/unifi-storage`, network config, SSH
   host keys, and the fstab lines for md0 and md3. Bind them from vda, or
   copy them into the upper.
4. Apps: install the deb13 builds of Protect, Access, ms/msr/msp/mst and ds
   into the upper with dpkg; the image bundles an older Protect. The
   alternative is Ubiquiti's own app persistence, which ships in the image:
   `ubnt-dpkg-cache` and `ubnt-dpkg-rescue` with `/persistent/dpkg/trixie`.
5. Re-lay the shims into the upper:
   - `install-shims.sh`: `ubnt-tools`, the `ubntnas` guard by
     `dpkg-divert`, smartctl;
   - `install-storage.sh`: `ustorage`, `ustated-shim`, `provision-storage`,
     the mdadm wrapper, the storage patch script;
   - the mask list, plus `uscsi-reset-wipe`.

   Then run `update-unifi.sh --verify`.
6. Postgres stays 14. Re-index if 14-main's collation is not `C` (glibc 2.31
   -> 2.41).

**Every later upgrade:**

1. Download the firmware and verify its SHA-256.
2. Extract `rootfs.new`.
3. Optionally review the release's updater steps: run
   `updater -t top -d -v <current> -p <file>` as `nobody` in a chroot with
   no network, as was done for this section. It lists what the release would
   run, which makes it a cheap per-release checklist and a candidate for
   `--check`.
4. Snapshot, reboot, re-lay the shims, run `--verify`.

Rollback of the OS image alone is a rename of `rootfs.bkp`; the snapshot
covers `/data`.

**An extra virtual disk so Ubiquiti's own upgrader runs?** Possible, not
worth it. What it would take:

- **A sysid of `ea1a` or `ea20`.** The shim's `ea16` points at raw flash,
  which `ubntnas` would erase and rewrite. `ubntnas` reads only
  `/proc/ubnthal/system.info`, and a procfs entry needs a kernel module. A
  stub module is small, but every Ubiquiti component that reads
  `/proc/ubnthal` would then see it too: unifi-core, and `ubnt-systool`'s
  anonid path (`seed-anonid.sh` relies on its absence).
- **`/dev/boot1` and `/dev/boot2`.** udev `SYMLINK` rules to partitions of
  the extra disk would do. `ubntnas` checks only the `/dev/boot` prefix and
  mounts by path, with p2 mounted at `/boot/firmware`.
- **`/dev/mtdblock0`, `1`, `2`, `6`.** `block2mtd` on further partitions,
  created in order so the numbers land right, with 6.0's u-boot preloaded
  so the compare skips the write.
- **A root image already booted from that disk.** `/dev/loop0` must be
  backed by a file named `rootfs` or `rootfs.bkp`, or `ubntnas` fails
  before writing `rootfs.new`. So the fake disk can only work on top of
  the device model above, never instead of it.
- **What it would add on top of that model:**
  - a uImage the VM cannot boot;
  - a flag in a fake config flash;
  - the updater's top and bottom stages run in the old system.
    `PreStageTrixieCache` needs Ubiquiti's servers: an isolated clone
    blocks there, and the live VM would contact them as the live console.
    `CleanDirectSystemdLinks` edits the VM's units.

  The one useful output, `rootfs.new`, the model's own swap already
  produces. So the fakes buy nothing and carry a wide blast radius.

Copy the device's model, not its tool.

**Recommendation.** Option 2 stays the decision. Option 3 is worth building
only if repacking keeps breaking on Debian 13, or if Ubiquiti stops
publishing deb11 app builds before the trixie guest is ready.

### 3. What 6.0 does to the data array

| Item | Finding | Rolls back with a snapshot? |
|------|---------|-----------------------------|
| md3 RAID metadata and the ext4 on it, on the VM | Ubiquiti's storage daemons (`usd`, `usdbd`, `ustated`) stay masked; md3 is assembled and mounted by the VM's own scripts. Nothing from 6.0 that runs on the VM writes md metadata or ext4 features (unit lists, mask loop, `/srv` and `/volume1` paths in units, tmpfiles and hooks: the same set in both images) | Not touched |
| md3 under a Debian 13 kernel (options 2 and 3: kernel 6.12, mdadm 4.4, e2fsprogs 1.47) | Assembling and mounting do not change the 1.2 superblock format or ext4 feature flags; only `mkfs`, `tune2fs -O` or `mdadm --grow` would. Reasoning from tool behaviour, not tested: record `dumpe2fs -h /dev/md3` features and `mdadm --detail` before and after on the clone | Not touched, if nobody runs those |
| 6.0 `ustd` on a real UNVR | New modules: `fsck_controller` (fsck started on request, with a remount), `raid_history` (a JSON history of RAID events; where it is stored was not found), `deferred_mount` (flags under `/run`), `zfs_label` (read-only WORM probe). From module names and docstrings only: they are compiled Cython. All masked on the VM | n/a on the VM |
| Flash storage migration (`unvrFlashStorageMigrationState`) | Same code in 5.1.33 and 6.0.11. unifi-core offers it only when the board is a UNVR with sysid `ea16`. On those units the updater's `AutoUNVR4USBMigrate` sets `/config/.need-migrate-userdev`. The next boot then creates `md1` (RAID1, metadata 1.2, homehost = serial) over every data disk's partition 3, may grow p3 from 1 GiB to 3 GiB in the partition table when the gap before the next partition allows, copies the overlay off the USB stick, and zeroes its first 32 MB. Also read from `ui-boot-nand`, all on p3 and partition tables, never p5/md3: before creating `md1` it zeroes the md superblock on every data disk's p3; it creates `md1` whenever the USB stick is missing, flag or not, and can then write a new partition table onto a blank disk; and it retries the p3 grow on every boot, unconditionally when nothing follows p3. Ubiquiti describes this for UNVRs with datecode 2048 or earlier as moving data from failing flash to a mirror on the HDDs ([help article](https://help.ui.com/hc/en-us/articles/11621161633943); official source, but read here only through a search-engine summary because this session could not reach help.ui.com, so medium confidence; it names no sysid). On the VM: the `ustorage` shim answers `rwfs check` with `canMigrate: false`, so unifi-core records `AUTO_MIGRATION_PENDING` (meaning "not migrated, cannot migrate"; that is the value in `firmware.yaml`) and never calls `rwfs migrate` (a no-op in the shim anyway). The updater step would see `ea16` on the VM (section 1) but only runs if `ubntnas` gets past its own sysid read, and then needs `/mnt/.rwfs` and a config flash. Ubiquiti's initramfs never runs | Inert on the VM |
| Protect | Protect 7.3.70 has the same version for deb11 and deb13, so 6.0 brings no Protect migration. Its database is on `/data` (vda); recordings are on md3 | DB yes, recordings no. Restoring `/data` after the system has recorded for a while leaves recordings written since the snapshot as files with no rows, and recordings removed by retention since then as rows with no files. That skew, not a format change, is what does not roll back, for any upgrade. Keep the window short; how Protect treats the orphans is for the clone to show |
| unifi-core | One new migration in 6.0.11: `20251104145507_add_smtp_tls_settings` (two boolean columns on `smtp_settings`, with a down step). Database `unifi-core` on port 5432, the 14-main cluster under `/data` | Yes |
| Postgres | Still 14 (same on-disk format); collation as in "Route to 6.0" | Yes (on `/data`) |
| `ustorage` / WORM | unifi-core 6.0 asks `worm check` only on models with `storage.supportsWorm` (not the UNVR); the shim answers "no WORM". 6.0's `uscsi-reset-wipe` adds NVMe wiping, ZFS-label zeroing and a WORM gate, all only after a format reset (section 1) | n/a |
| Other app data under `/srv` on md3 (Access, ms/ds, Protect config backups) | Same app versions on both platforms today | Content written after the snapshot stays |

In short: on the VM, 6.0 itself changes nothing in md3's metadata or
filesystem format. What a snapshot does not undo is content that apps write
to the array after it was taken.

### Checks only the real UNVR (or the real disks) can settle

All read-only; the unit can stay offline.

```bash
grep -E '^(systemid|boardrevision)=' /proc/ubnthal/system.info   # ea16 (NAND) or ea1a (eMMC)
cat /proc/mtd; cat /proc/cmdline                                 # flash partitions; root=rootfs or rootfs.bkp
lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,MOUNTPOINT              # /dev/boot1..5, or sdq / md1
findmnt -o TARGET,SOURCE,FSTYPE / /boot/firmware /mnt/.rwfs /data /var/log
ls -la /boot/firmware/                                           # rootfs and rootfs.bkp sizes
mkdir /tmp/bkp && mount -o ro,loop /boot/firmware/rootfs.bkp /tmp/bkp && cat /tmp/bkp/usr/lib/version; umount /tmp/bkp   # which release the backup is
cat /proc/mdstat; ustorage rwfs check                            # is there an md1; migrated or not
ls /persistent/dpkg/                                             # app caches the rescue uses
sfdisk -d /dev/sda                                               # data-disk layout (the initramfs's own layout starts p5 at 16777216)
```

On the VM: `systemctl is-enabled uscsi-reset-wipe.service` and
`ls /proc/mtd` (expected: enabled, and no such file). If its data disks came
from the UNVR, also run `mdadm --examine /dev/sd[a-d]3` (read-only). If those partitions carry an
`md1` superblock, they hold the UNVR's old overlay, with its identity.
Never assemble them on a clone.

## Open questions

- Whether a booted 6.0 renders the Storage panel's disk list from the shim
  alone, as the code reading says. Check on a Debian 13 clone.
- Whether Patch A still does anything on 5.1.33: in unifi-core 5.1.132 the
  patched snapshot (`Aj()`) is used only when `NODE_APP_INSTANCE=cloud`; the
  UNVR path already reads `getV1StorageState()` from the gRPC store. If so, the
  disk list on 5.1.33 comes from the shim and Patch A is inert.
- Whether `ubnt-systool network-fec` and the systemd-mode WebRTC worker behave
  on a VM.
- When Ubiquiti stops publishing `uos-deb11-arm64` app builds.
- Whether the `ubntnas` guard should also refuse `system reset`:
  reset2defaults (the UI's Reset, with "format" optional) runs `ubntnas system
  reset --no-reboot [--do-format] ...` the same way. It is inert on the VM
  today ("How a real UNVR upgrades in place", section 1): `ubntnas` stops
  without `/proc/ubnthal`, and the wipe itself only happens at the next boot,
  in code that the VM either never runs or that finds nothing to act on. Recommended for symmetry, together with
  masking `uscsi-reset-wipe`; left passing through until decided.
- Pre-existing, not 6.0: the installer downloads the firmware without a
  SHA256 check; a Debian `mdadm` update replaces the `/sbin/mdadm` wrapper;
  the `ustorage` shim has no `disk clean`, so the UI's per-disk erase reports
  success and does nothing.

## Method

```bash
API=https://fw-update.ubnt.com/api
curl -s "$API/firmware-latest?filter=eq~~product~~unifi-nvr&filter=eq~~channel~~release&filter=eq~~platform~~UNVR"
curl -s "$API/firmware?filter=eq~~product~~unifi-nvr&filter=eq~~platform~~UNVR&filter=eq~~version_major~~5&filter=eq~~version_minor~~1&filter=eq~~version_patch~~33"
```

| Image | API version | SHA256 (API = downloaded) | Size |
|-------|-------------|---------------------------|------|
| 5.1.33 | v5.1.33+44ce47b, created 2026-09-10 | b170e97f9b7a703947380aed1108221e70ab18074b986906aca9df10891ca1e0 | 787559347 |
| 6.0.11 | v6.0.11+dd9ab55, created 2026-10-07 | 4f1317954aad293b6b0b0272a8948a2cae9676a78252458093181da41823ffc8 | 839003867 |

Protect 7.3.70 was fetched for both platforms the same way (SHA256 verified)
to read its `Depends`.

```bash
binwalk -y squashfs fwupdate.bin                       # one zstd squashfs
unsquashfs -o <offset> -d squashfs-root fwupdate.bin
dpkg-query --admindir=squashfs-root/var/lib/dpkg -W -f='${Package}\t${Version}\t${Maintainer}\n'
dpkg-repack --root=squashfs-root --arch=arm64 <pkg>    # as update-unifi.sh does
# qemu-user-static + binfmt, then chroot into either root for the spot checks
```

Re-run the tests with the images unpacked:

```bash
FW_ROOT_51=/path/5.1.33/squashfs-root FW_ROOT_60=/path/6.0.11/squashfs-root \
    vm/tests/test_unifi_os6_compat.sh
```

## Test plan for an isolated clone

The clone must not reach the cameras, the live console, or the UniFi cloud
under the live console's identity (its board serial is derived from the NIC
MAC, which the clone keeps), and must not touch the live VM's disks, sockets
or host-side state.

1. **Make the clone's images.** Copy the OS image, the `/ssd1` image and the
   EFI vars file (QEMU writes to it) into a clone-only directory, for example
   with `vm-clone-backup.py`. Create **four new blank** qcow2 data images;
   never attach the live DAS disks.
2. **Start it by hand, not with `start-protect-vm.sh`.** That script always
   uses `vmnet-bridged` (the LAN), attaches the control channel, and defaults
   `QMP_SOCKET`/`CONSOLE_SOCKET` to the global `/var/run/protect-vm.*.sock`
   paths. QEMU would rebind those, and `snapshot.sh`, `vm-clone-backup.py` and
   the DAS fault handler would then talk to the clone. Use a hand-written
   `qemu-system-aarch64` command with: the clone's images and EFI vars; QMP
   and serial on sockets inside the clone directory; no control-channel
   chardev (so `md-layout-report.sh` cannot write the live `md-layout.map`
   that the DAS fault handler reads); and
   `-netdev user,id=net0,restrict=on,guestfwd=...` pointing at an allowlisting
   HTTPS proxy on the host. Never run `snapshot.sh` or `vm-clone-backup.py`
   with the live conf against the clone; take the clone's snapshots with
   `qemu-img snapshot` while it is shut down.
3. **Network allowlist.** The proxy permits only `fw-update.ubnt.com`,
   `fw-update.ui.com` and `fw-download.ubnt.com` (add `deb.debian.org`,
   `security.debian.org`, `apt.postgresql.org`, `nginx.org`,
   `apt.artifacts.ui.com` for step 12; those plus `www.postgresql.org` and
   `github.com` for step 13). Export `https_proxy`/`http_proxy` only in the
   root shell that runs the scripts; systemd services, unifi-core included,
   get no proxy and so no way out. Check before going on: `ip route` shows only
   the user-mode route; `getent hosts api.ui.com` and
   `curl -m5 https://api.ui.com` fail without the proxy; a camera's address
   does not answer. Move `/usr/local/etc/md-health-watch.conf` (Pushover
   credentials) aside on the clone so its watchers cannot send anything.
4. **Storage for the clone.** At first boot no array exists, so provision the
   four blank images (Storage wizard, or `AUTOMODE=true` in
   `/etc/default/unifi-storage` for one boot). Until then `--verify` reports
   `md array [UUUU]` as FAIL, which is expected.
5. **Deliver the branch** (scripts ISO) and run
   `bash vm/tests/test_unifi_os6_compat.sh`: 91 passed, 0 failed.
6. **Re-lay on 5.1.33**: `install-storage.sh`, then `systemctl restart unifi-core`;
   `journalctl -u unifi-core-storage-patch -b` shows "already applied" or
   "Patch A applied", not "not needed". `update-unifi.sh --verify`: all OK.
   While there, for open question 2:
   `tr '\0' '\n' < /proc/$(systemctl show -p MainPID --value unifi-core)/environ | grep NODE_APP_INSTANCE`
   (`systemctl show -p Environment` does not include `EnvironmentFile` values).
7. **`update-unifi.sh --check`**: "UniFi OS 5.1.33 (up to date)",
   "OS track: 5 (Debian bullseye, apps from uos-deb11-arm64)", and the note
   naming v6.0.11 as outside the track. `--os-track 6 --check` adds the
   "not the 5.x line" warning; `--os-track 5.1.31 --check` adds the downgrade
   note; `--os-track bogus --check` warns and shows UniFi OS "not
   compared", and `OS_TRACK=bogus update-unifi.sh --sync-os` stops at once.
   `--access` says "Already at latest version" (it reinstalled Access on
   every run before).
8. **`KEEP_WORKDIR=1 update-unifi.sh --sync-os --yes`** (track 5; the kept
   `/opt/unifi-update/fwupdate.bin` is used in step 9a): downloads 5.1.33, verifies
   it, prints "No package changes detected" and stops nothing (before this
   PR it listed Protect and its AI package as downgrades and restarted the
   stack). A no-change sync never reaches the mask loop, so `ufcd` is not
   masked by it; on 5.x that is fine, the unit does not exist.
9. **The guard**: `OS_TRACK=6 update-unifi.sh --sync-os --yes`. Expect at
   once, before any snapshot request or download: `ERROR: UniFi OS 6.0.11 is
   not the 5.x line built on Debian 'bullseye'`, exit 1. `unifi-protect`
   stays active and `/usr/lib/version` is unchanged. (The check on the
   unpacked image behind it is covered by the unit tests.)
9a. **The console update guard.** After step 6 (or any `install-shims.sh`
   run): `head -3 /usr/bin/ubntnas` shows `ubntnas-vm-guard`,
   `dpkg-divert --list /usr/bin/ubntnas` names `/usr/bin/ubntnas.real`, and
   `ubntnas system upgrade /nonexistent -f --no-reboot` prints the refusal
   and exits 1 (`journalctl -t ubntnas-vm-guard` logs it). Only once those
   hold, and on the clone only, the full UI path with a valid image (it
   checks the file with `fwinfo` before calling `ubntnas`):
   `ubnt-systool fwupdate /opt/unifi-update/fwupdate.bin` from step 8 must
   end with the same refusal as its reason. A harmless subcommand such as
   `ubntnas --help` still reaches the real binary through the guard. Then
   remove `/opt/unifi-update`.
10. **The install path, both ways (optional; it downgrades the clone):**
    `OS_TRACK=5.1.31 update-unifi.sh --sync-os --yes`, then
    `OS_TRACK=5 update-unifi.sh --sync-os --yes`. Each run must install,
    stamp `/usr/lib/version` with its release, mask `ufcd`
    (`systemctl is-enabled ufcd.service` -> `masked`) and pass `--verify`;
    afterwards the `ubntnas` guard is still in place and
    `/usr/bin/ubntnas.real` is the reinstalled package's binary (the
    diversion at work).
11. **Reboot the clone**: `--verify` all OK; `systemd-analyze critical-chain
    local-fs.target` shows `provision-storage.service` before it;
    ms/msr/msp/mst active; `ubnt-systool anonid` equals
    `/data/protect-on-mac/anonid`.
12. **Deferred: the 6.0 stack itself**, on the fresh trixie guest of "Route to
    6.0" option 2 (the chosen one), once `install-protect-baremetal.sh` is
    ported to trixie, isolated the same way with the step 3 Debian hosts
    added. Record: the install's firmware pick (6.0.x on trixie);
    unifi-core 6.0.123
    active; the Storage panel lists the guest's disks; the patch journal says
    "not needed"; `ufcd` masked and inactive; 14-main, 14-protect, 14-access
    up and whether 14-apps exists and runs; Protect from
    `uos-deb13-arm64`; `head -3 /sbin/mdadm` is the wrapper;
    the collation of every cluster
    (`for p in 5432 5433 5434 5435; do psql -p $p -U postgres -Atc 'select datname, datcollate from pg_database'; done`);
    unifi-core log lines about `network-fec`, the WebRTC worker and
    `audit-shipper`.
13. **Fresh-install check (optional)**: a new Debian 11 VM, started the same
    isolated way (Phase 0 also uses the control channel, so the step 2 rules
    apply), with the step 3 hosts for Phases 1 to 3 allowed.
    `install-protect-baremetal.sh` logs the 5.1.33 firmware URL and passes
    the guard. For the refusal, use another fresh VM, or delete
    `/opt/unvr-install/firmware-build/fwupdate.bin` first (Phase 4 reuses it):
    with `OS_TRACK=6` it stops at Phase 4 with the Debian error, removes the
    download, and `/usr/lib/version` is not written.
14. Discard the clone and its images.
