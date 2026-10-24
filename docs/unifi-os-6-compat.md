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
  stamped `/usr/lib/version` with 6.0.11, restarted the stack and from then on
  reported "up to date". unifi-core reports that file as the console's
  firmware version. A fresh `install-protect-baremetal.sh` run would also
  pull 6.0.11 and fail in Phase 5, after writing the 6.0.11 version file.
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
| 4 | New `ufcd.service` (UI fan control, package `ustd`): `WantedBy=local-fs.target`, `Wants/After=usdbd.service`, `Restart=always` | unit file in 6.0 `ustd` | Masked in both installers' lists (harmless on 5.x) |
| 5 | Storage Patch A anchor gone: 6.0's unifi-core never calls `ustorage space inspect`, so the patch script would raise its anchor alert (journal error + Pushover) on every unifi-core start | real 6.0.11 `service.js`: 0 matches | Fixed: recognised as not needed, exits 0 quietly; 5.1 path unchanged |
| 6 | App debs are per Debian base: `uos-deb11-arm64` and `uos-deb13-arm64` (no deb12) | API queries for unifi-protect, unifi-access, ai-feature-console, ms, msr, ds, protect-verify | Fixed: platform derived from `/etc/os-release` (11 -> deb11, so unchanged today) |

Everything else in the brief's checklist is unchanged or changed harmlessly;
details follow.

## Comparison

### Packages

| Item | 5.1.33 | 6.0.11 | Verdict |
|------|--------|--------|---------|
| Debian base | 11.11 bullseye | 13.7 trixie, merged /usr (`bin`, `sbin`, `lib` are links) | changed, breaks us (item 1) |
| Packages in the image | 437 | 429 | - |
| Ubiquiti packages (`@ui.com`/`@ubnt.com`) | 50 | 51 | 3 new, 2 removed, 30 changed, 18 same version |
| New | - | `bluez-tools-ui` 5.82.1 (`bccmd`, `hciattach_ui`), `diskclass` 1.1.0 ("HDD/SSD classifier"; no caller found in units, udev rules, `/usr/bin`, `/usr/sbin`, ustd or unifi-core), `fluent-bit` 5.0.9 (audit log shipper) | changed, harmless; they are repacked and installed like the rest |
| Removed | `node20` 20.19.5, `openssh-server-keygen` 0.3 | - | changed, harmless (nothing in the repo uses node20) |
| Same version, rebuilt | e.g. `jq`/`libjq1` 1.6~ubnt: libc6 >= 2.17 -> >= 2.34/2.39 | | the version string hides a trixie rebuild; covered by item 1 |
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
| `ms`, `msr`, `msp`, `mst` | identical unit files | unchanged; the `10-wait-for-volume1.conf` drop-ins still apply |
| `unifi-core` | `Wants=` adds `fluent-bit-audit.service`; `Sockets=audit-shipper.socket`; `MemoryMax` 300M -> 1536M, `MemorySwapMax=0`, `OOMScoreAdjust=-900`; `$UNIFI_CORE_HEAP_OPTS`; `KillMode=control-group`; `unifi-core.service.d/memory.conf` removed | changed, harmless; only matters on a Debian 13 guest (the socket's user `audit-shipper` must exist there) |
| `ulp-go` | `Restart=always`, memory limits | changed, harmless |
| `postgresql@14-protect` | only `memory-limits.conf` values | unchanged for us; `10-assert-datadir.conf` still applies, `pg_conftool` comes from the same postgresql-common 293 |
| `local-fs` ordering | `local-fs.target.wants` gains only `ufcd`; `local-fs-pre.target.wants` (uscsi-reset-wipe, uscsi-rescan, uscsi-disk-ready) unchanged | unchanged once ufcd is masked |
| New elsewhere | `fluent-bit-audit`, `audit-shipper.socket`, `unifi-audit-protect` (`chattr +a /data/audit`), `unifi-audit-cleanup.timer`, `unifi-protect-permission-repair` (bundled Protect), systemd 257's `capsule@`, oomd slice drop-ins | changed, harmless for the current VM |
| Boot hook `55-unmask.py` | now `unmask --no-reload` + one `daemon-reload`; the list it unmasks (`unifi-protect`, `postgresql@14-protect`, `uid-agent`, `smbd` ...) is identical and holds nothing we mask | unchanged |
| Boot hook `99-replay-late-mount` (new) | runs `ustorage space replay-late-mount` to replay usd's mount hooks | harmless: our `ustorage` exits 0 silently on unknown verbs, and `provision-storage.sh` already makes `/srv` |

### Paths and fields our shims and patches use

| What | 6.0.11 | Verdict |
|------|--------|---------|
| `ubnt-tools` (shim at `/sbin/ubnt-tools`) | still installed at `/sbin/ubnt-tools` by `ubnt-tools`. Callers are the same files with the same subcommands: `id` (unifi-core, pre-start hooks, ms pre-start, AI controller, `unifi-protect-tmpfs`, board-info cache hook) and `uuid` (`ubnt-systool`). Fields read: `board.sysid`, `board.shortname`, `board.bom`; new consumer `unifi-protect.service` (bundled Protect) reads `board.sysid`. unifi-core's EEPROM dump (`ubnt-tools id <file>`, behind a predicate) is the same code as in 5.1.33; the shim writes no file there, so if it runs it logs "Failed to read EEPROM" exactly as today | unchanged |
| `uled-ctrl`, `smartctl` | `/usr/bin/uled-ctrl`, `/usr/sbin/smartctl` | unchanged |
| `/usr/bin/ustorage` | still owned by `ustd`, so a sync still overwrites it and `install-storage.sh` re-lays it. Verbs unifi-core 6.0 calls: `config hotspare`, `config prefer`, `rwfs check`, `rwfs migrate`, `space nuke`, new `worm check`. `space inspect` is no longer called; `disk inspect` never was (only by Patch A) | `worm check` is gated by `features.storage.supportsWorm`, set only for an enterprise NAS model, not UNVR. Still answered now (done), in the real 6.0 output shape |
| unifi-core storage patch | Patch A anchor `iwe={space:e,disks:[],sdcards:[]};` and the `"ustorage",["space","inspect"]` call: 0 matches. Disks come from the gRPC store (`DiskState` stream -> `getV1StorageState()` / `getTransformedDisks()`), which `ustated-shim` feeds. Exec helper renamed `Q` -> `q` | needs a change in `unifi-core-storage-patch.sh` and `update-unifi.sh --verify` (done: "not needed") |
| storage gRPC API | `@ubnt/unifi-protobufs` 0.115.0 -> 0.143.0; still `storage/v1` and `v2` (no v3), same six v2 RPCs, still `127.0.0.1:11052`; only additive enum values (`DISK_RISK_REASON_INVESTIGATION_NEEDED`, `SPACE_ISSUE_TYPE_RAID_BAD_BLOCKS`, `CACHE_POLICY_LVM_RAND`); `accessory/v1` identical; grpc-js 1.14.1 -> 1.14.3 | unchanged; spot-checked below |
| UNVR model entry in unifi-core | storage still `{id:1,type:"raid",mountPoint:"/srv",path:"/dev/md3"}` (the `mdadm` wrapper's premise); adds `nonPrivateLocalDiscovery`, `discoverDevices` and a `webrtcWorker` run as a systemd unit | unchanged for the storage path |
| anonymous device id | `ubnt-systool do_anonid` unchanged: a valid `/var/run/anonymous_device_id` wins; unifi-core still calls `ubnt-systool anonid`; `configPath` still `/data/unifi-core/config` (settings.yaml) | unchanged; spot-checked below |
| ms/msr/msp/mst drop-ins, `postgresql@14-protect` drop-in | unit names and files unchanged | unchanged |
| `ustated` shim service | `ustated.service` identical; `node24` still `/usr/bin/node24` | unchanged |

### New hardware queries and checks a VM could fail

- `ufcd` (fan control): would restart forever. Masked by this PR.
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
    `--check` reads "up to date" and names 6.0.11 as outside the track.
  - Debian guard in `sync_os_packages`, right after extraction and before any
    service is stopped: refuses a firmware whose `VERSION_CODENAME` differs from
    the guest's, cleans the work dir, exits non-zero.
  - `/usr/lib/version` is copied only when the installed unifi-core equals the
    firmware's; otherwise an ERROR, the stack is still re-masked, re-shimmed
    and restarted as before, and the script exits 1 after cleanup.
  - `DEB_PLATFORM` from `/etc/os-release` (11 -> `uos-deb11-arm64`, 13 ->
    `uos-deb13-arm64`; overridable).
  - `ufcd` added to the mask loop; `--verify` checks it when the unit exists and
    accepts "Patch A not needed" on a bundle without `ustorage space inspect`.
  - `--check` compares OS versions as X.Y.Z.
  - The helpers sit above a "sourced: return" guard so tests can load them.
- `vm/installers/install-protect-baremetal.sh`: the same `OS_TRACK` default for
  Phase 4 (`FW_URL` still wins), the Debian guard before `/usr/lib/version` is
  written, `fw_api_href` picks the newest of a listing, `DEB_PLATFORM` for the
  Protect and AI queries, `ufcd` masked. The firmware-bundled
  `AIFC_STABLE_URL` pin stays deb11 (that path is documented as untested).
- `vm/storage/rootfs/usr/local/bin/unifi-core-storage-patch.sh`: exits 0 with
  "not needed" when the bundle has no `ustorage space inspect` call; the 5.1
  path, including the drift alert, is unchanged. `SVC`/`PUSH_CONF` can be set
  for tests.
- `vm/storage/rootfs/usr/bin/ustorage`: `worm check [--details]`.
- `vm/tests/test_unifi_os6_compat.sh`: 51 stubbed checks (no root, no VM, no
  network); 45 of them fail against the code before this PR. With
  `FW_ROOT_51`/`FW_ROOT_60` pointing at unpacked images it adds 4 checks
  against the real firmware.

Not changed, on purpose: `ustated-shim.js`, `install-shims.sh`,
`seed-anonid.sh`, the ms/msr/msp/mst and postgres drop-ins,
`provision-storage.service` (all verified unchanged or compatible above), and
`critical-services-watch.sh` (14-apps is left out until a booted 6.0 shows it
always runs; adding it now would alert on 5.1.33 where it does not exist).

## Route to 6.0 (proposal, untested)

6.0 needs the guest on Debian 13 first. Two ways, both to be proven on an
isolated clone:

1. **In-place** (keeps `/data`: identity, databases, the anonid store): with the
   Ubiquiti pin in place, `apt full-upgrade` bullseye -> bookworm -> trixie,
   switching the pgdg and nginx.org sources at each step
   (`fix_apt_ubiquiti_sources.sh` already follows `VERSION_CODENAME`). Re-lay
   the `mdadm` wrapper if mdadm was upgraded (trixie moves it to
   `/usr/sbin/mdadm`; the wrapper is not a dpkg diversion) and run
   `install-shims.sh` for smartctl. Then `OS_TRACK=6 update-unifi.sh --all`:
   the guard passes, apps come from `uos-deb13-arm64`. Postgres stays 14 (same
   on-disk format); check every cluster's collation, since glibc goes from 2.31
   to 2.41 and indexes on text in a glibc locale other than C would need a
   REINDEX. UniFi's own `pg-cluster-upgrade` creates clusters with
   `--locale=C`; the 14-main cluster made by the installer's
   `apt-get install postgresql-14` took the guest's default locale.
2. **Fresh Debian 13 guest** + restore of the UniFi OS backup. Needs
   `install-protect-baremetal.sh` ported to trixie (its bullseye check, Phase 1
   package list, jq/libjq1 handling) and is a larger change than this PR.

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
- Pre-existing, not 6.0: the installer downloads the firmware without a
  SHA256 check, and a Debian `mdadm` update replaces the `/sbin/mdadm` wrapper.

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
under the live console's identity, and must not touch the live VM's disks.

1. **Make the clone.** Copy the OS image and the `/ssd1` image (for example with
   `vm-clone-backup.py`). Give it two or more **new blank** data images
   instead of the DAS; never attach the live DAS disks. Start it **without the
   host control channel** (or with a host helper configured for the clone's
   images only): `update-unifi.sh` asks the host to snapshot over that
   channel, and the live helper would snapshot the live VM. Take snapshots of
   the clone's images from the host by hand.
2. **Network.** QEMU user networking with `restrict=on` (no outbound, no LAN),
   plus one `guestfwd` to an allowlisting HTTPS proxy on the host that permits
   only `fw-update.ubnt.com`, `fw-update.ui.com` and `fw-download.ubnt.com`
   (add `deb.debian.org`, `security.debian.org`, `apt.postgresql.org`,
   `nginx.org`, `apt.artifacts.ui.com` for step 9 only). Export
   `https_proxy`/`http_proxy` only in the root shell that runs the scripts;
   systemd services, unifi-core included, get no proxy and so no way out.
   Confirm before going on: `ip route` shows only the user-mode route,
   `curl -m5 https://api.ui.com` fails without the proxy, a camera's address
   does not answer.
3. **Deliver the branch** (scripts ISO) and run
   `bash vm/tests/test_unifi_os6_compat.sh`: 51 passed, 0 failed.
4. **Re-lay on 5.1.33**: `install-storage.sh`, then `systemctl restart unifi-core`;
   `journalctl -u unifi-core-storage-patch -b` shows "already applied" or
   "Patch A applied", not "not needed". `update-unifi.sh --verify`: all OK.
   While there: `systemctl show unifi-core -p Environment` and
   `cat /etc/default/unifi-core` for `NODE_APP_INSTANCE` (open question 2).
5. **`update-unifi.sh --check`**: "UniFi OS 5.1.33 (up to date)",
   "OS track: 5 (Debian bullseye, apps from uos-deb11-arm64)", and the note
   naming v6.0.11 as outside the track. `--os-track bogus` is refused.
6. **`update-unifi.sh --sync-os --yes`** (track 5): downloads 5.1.33, verifies
   it, "No package changes detected". Then `--verify` still all OK, and
   `systemctl is-enabled ufcd.service` says `masked`.
7. **The guard**: `OS_TRACK=6 update-unifi.sh --sync-os --yes`. Expect the
   download and extraction, then `ERROR: UNVR firmware v6.0.11+dd9ab55 is built
   on Debian 'trixie'; this system runs Debian 'bullseye'.`, exit 1,
   `/opt/unifi-update` emptied. Throughout, `unifi-protect` stays active (watch
   `systemctl is-active unifi-protect` in a second shell) and
   `/usr/lib/version` is unchanged.
8. **Reboot the clone**: `--verify` all OK; `systemd-analyze critical-chain
   local-fs.target` shows `provision-storage.service` before it; ms/msr/msp/mst
   active; `ubnt-systool anonid` equals `/data/protect-on-mac/anonid`.
9. **Optional, exploratory: the 6.0 route** on a fresh snapshot of the clone,
   following "Route to 6.0" option 1. Record: whether the dist-upgrades keep the
   pinned Ubiquiti packages; `OS_TRACK=6 update-unifi.sh --all` result;
   unifi-core 6.0.123 active; the Storage panel lists the test disks; the patch
   journal says "not needed"; `ufcd` masked and inactive; 14-main, 14-protect,
   14-access up and whether 14-apps exists and runs; Protect 7.3.70 from
   `uos-deb13-arm64`; `head -3 /sbin/mdadm` still the wrapper;
   `psql -p 5433 -U postgres -Atc 'select datname, datcollate from pg_database'`;
   unifi-core log lines about `network-fec`, the WebRTC worker and
   `audit-shipper`.
10. **Fresh-install check (optional)**: a new isolated Debian 11 VM with the same
    network rules. `install-protect-baremetal.sh` logs the 5.1.33 firmware URL
    and passes the guard; with `OS_TRACK=6` it stops at Phase 4 with the
    Debian error and `/usr/lib/version` is not written.
11. Discard the clone and its images.
