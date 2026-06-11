#!/usr/bin/env node24
'use strict';
/******************************************************************************
 * ustated-shim.js — storage gRPC replacement for the Protect VM.
 *
 * WHY
 *
 * unifi-core renders its Storage panel — and gates the first-boot storage
 * setup wizard — from a gRPC StorageAPI it subscribes to on 127.0.0.1:11052.
 * On a real UNVR that endpoint is served by `ustated`, fed by `usd`. Neither
 * can run on this VM, so this shim serves the API directly.
 *
 * DUAL-VERSION — serves storage v1 AND v2
 *
 * unifi-core's storage API is versioned and the version tracks the firmware:
 *   - UniFi OS 5.0.x  -> unifi.firmware.storage.v1.StorageAPI
 *   - UniFi OS 5.1.x  -> unifi.firmware.storage.v2.StorageAPI
 * The two wire formats are incompatible. Rather than pin the shim to one
 * firmware, it registers BOTH services on the same :11052 gRPC server — they
 * have distinct method paths (/unifi.firmware.storage.v1.StorageAPI/... vs
 * .../v2/...), so a single server hosts both and unifi-core connects to
 * whichever its firmware speaks. A version whose generated protobuf modules
 * are not installed is simply skipped, so the shim works unchanged on a
 * 5.0.x or a 5.1.x VM.
 *
 * Both services are built on Ubiquiti's own generated protobuf + gRPC
 * modules, loaded straight from unifi-core's node_modules, so the wire
 * format is exact.
 *
 * v2 SCHEMA NOTES (differs structurally from v1)
 *   - DiskState returns repeated SlotDisk { index, state, disk } — the disk
 *     wrapped in a bay/slot, not a flat list.
 *   - Disk { device, status, info, stats, identifier }; identity + SMART
 *     moved into DiskInfo.smartInfo / DiskInfo.smartAttr; array membership
 *     into DiskInfo.raidState; health flags into DiskInfo.abnormalInfo.
 *   - No RaidState RPC; raid topology lives in SpaceState
 *     (Space.info.raidList). New CacheSlotState RPC.
 *   - StorageSettings carries a StorageSetting { mode, global }.
 *
 * UNCONFIGURED-STORAGE SIGNAL (both versions)
 *
 * A fresh VM with blank data disks must make the wizard prompt the operator
 * to choose a RAID type. unifi-core treats storage as unconfigured when no
 * RAID/StorageSetting is reported and SpaceState has no primary/DATA space —
 * exactly what this shim emits until an array exists. Every present, healthy,
 * not-in-RAID disk is reported as a "normal" disk and counted toward the
 * RAID minimums.
 *
 * REQUIRES
 *   - node24 (on PATH)
 *   - unifi-core's node_modules — grpc-js + the @ubnt/unifi-protobufs
 *     storage modules (v1 and/or v2).
 *   - smartctl at /usr/sbin/smartctl (the proxy wrapper, for real SMART).
 *   - `ustated` masked + stopped so :11052 is free.
 ******************************************************************************/

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// unifi-core's node_modules — grpc-js + generated protobuf/gRPC modules.
const NM  = '/usr/share/unifi-core/app/node_modules';
const PB1 = NM + '/@ubnt/unifi-protobufs/unifi/firmware/storage/v1';
const PB2 = NM + '/@ubnt/unifi-protobufs/unifi/firmware/storage/v2';

const grpc     = require(NM + '/@grpc/grpc-js');
const wrappers = require(NM + '/google-protobuf/google/protobuf/wrappers_pb.js');

const LISTEN         = '127.0.0.1:11052';
const STORAGE_VOLUME = '/volume1';
const SMARTCTL       = '/usr/sbin/smartctl';
const POLL_MS        = 30000;          // re-stream interval
const SMART_TIMEOUT  = 20000;          // hard ceiling per smartctl call
const U32_MAX        = 4294967295;

// Uncorrectable-sector count at which a disk is reported at risk. Real-UNVR
// capture: a disk with 5 uncorrectable sectors was flagged by usd, one with
// 2 was not — 4 splits the observed cases.
const UNC_RISK_THRESHOLD = 4;

function log(msg) {
  process.stderr.write('[ustated-shim] ' + msg + '\n');
}

function u32(v) {
  v = Number(v) || 0;
  return Math.max(0, Math.min(Math.trunc(v), U32_MAX));
}

function boolValue(b) {
  const v = new wrappers.BoolValue();
  v.setValue(!!b);
  return v;
}

///////////////////////////////////////////////////////////////////////////////
// Storage inspection — /sys, /proc, smartctl  (version-agnostic)
///////////////////////////////////////////////////////////////////////////////

function readFile(p) {
  try { return fs.readFileSync(p, 'utf8').trim(); } catch (e) { return ''; }
}

function safeReaddir(p) {
  try { return fs.readdirSync(p); } catch (e) { return []; }
}

function volumeDevice(mountpoint) {
  try {
    for (const line of fs.readFileSync('/proc/self/mounts', 'utf8').split('\n')) {
      const parts = line.split(/\s+/);
      if (parts.length >= 2 && parts[1] === mountpoint) return parts[0];
    }
  } catch (e) {}
  return '';
}

function baseName(p) {
  return p.split('/').filter(Boolean).pop() || '';
}

// String-only parent-disk derivation, for when sysfs can no longer resolve a
// member because its disk was pulled: 'sda5' -> 'sda', 'nvme0n1p5' -> 'nvme0n1'.
function parentDiskName(member) {
  const m = member.match(/^(nvme\d+n\d+)p\d+$/);
  return m ? m[1] : member.replace(/\d+$/, '');
}

// A partition (sde5) has a 'partition' attr in sysfs; its parent whole disk
// is the directory above it. A whole disk resolves to itself.
function parentDisk(node) {
  try {
    if (fs.existsSync('/sys/class/block/' + node + '/partition')) {
      return baseName(path.dirname(fs.realpathSync('/sys/class/block/' + node)));
    }
    return node;
  } catch (e) {
    return parentDiskName(node);
  }
}

function deviceSizeBytes(node) {
  const sectors = parseInt(readFile('/sys/class/block/' + node + '/size'), 10);
  return Number.isFinite(sectors) ? sectors * 512 : 0;
}

// The whole disk that carries the OS — never treated as a data disk.
function osDisk() {
  const src = volumeDevice('/data') || volumeDevice('/');
  return src ? parentDisk(baseName(src)) : '';
}

// Every present whole data disk (SATA / virtio / NVMe), OS disk excluded.
function dataDisks() {
  const os = osDisk();
  const out = [];
  for (const n of safeReaddir('/sys/block').sort()) {
    if (!/^(sd[a-z]+|vd[a-z]+|nvme\d+n\d+)$/.test(n)) continue;
    if (n === os) continue;
    if (deviceSizeBytes(n) <= 0) continue;
    out.push(n);
  }
  return out;
}

// md member basename -> kernel md state ('in_sync', 'faulty', 'spare', ...).
function mdMemberStates(md) {
  const states = {};
  const base = '/sys/block/' + md + '/md';
  for (const e of safeReaddir(base)) {
    if (e.startsWith('dev-')) states[e.slice(4)] = readFile(base + '/' + e + '/state');
  }
  return states;
}

// The md array backing /volume1, or '' when no array is mounted there.
function primaryArrayName() {
  const n = baseName(volumeDevice(STORAGE_VOLUME));
  return n.startsWith('md') ? n : '';
}

// True when a member is mid-rebuild. The kernel reports a rebuilding
// member's state as 'spare' for the entire resync, but it occupies a real
// slot from the moment recovery starts — an idle hot spare's slot reads
// 'none'. Without this test a disk being rebuilt INTO the array is
// indistinguishable from a spare waiting beside it, and the console paints
// a degraded, rebuilding array as healthy-with-a-hot-spare.
function memberIsRebuilding(md, member, state) {
  if (state.indexOf('spare') === -1) return false;
  const slot = readFile('/sys/block/' + md + '/md/dev-' + member + '/slot');
  return slot !== '' && slot !== 'none';
}

// md sync/rebuild state: { action, degraded, pct }.
function mdSyncState(md) {
  const base = '/sys/block/' + md + '/md';
  const action = readFile(base + '/sync_action') || 'idle';
  const degraded = parseInt(readFile(base + '/degraded'), 10) || 0;
  let pct = 0;
  const m = readFile(base + '/sync_completed').match(/^(\d+)\s*\/\s*(\d+)/);
  if (m && Number(m[2]) > 0) pct = Math.round(Number(m[1]) / Number(m[2]) * 100);
  return { action: action, degraded: degraded, pct: pct };
}

// Parsed `smartctl --json -x`; {} on any failure. smartctl's exit status is
// a bitmask, so a thrown error still carries valid JSON on stdout.
function smart(node) {
  try {
    const out = execFileSync(SMARTCTL, ['--json', '-x', '/dev/' + node],
      { timeout: SMART_TIMEOUT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    return JSON.parse(out || '{}');
  } catch (e) {
    if (e && e.stdout) { try { return JSON.parse(e.stdout); } catch (_) {} }
    return {};
  }
}

function attrRaw(table, id) {
  for (const a of table || []) {
    if (a.id === id) return (a.raw && a.raw.value) || 0;
  }
  return 0;
}

// SMART-derived risk signals, version-agnostic. v1 maps these to its
// abnormal_state_reasons strings; v2 maps them to DiskRiskReason enums.
function diskRiskSignals(sd) {
  const status = sd.smart_status || {};
  const table = (sd.ata_smart_attributes && sd.ata_smart_attributes.table) || [];
  return {
    smartFailed: ('passed' in status) && status.passed === false,
    tooManyUnc:  u32(attrRaw(table, 198)) >= UNC_RISK_THRESHOLD,
  };
}

function anyRisk(sig) { return sig.smartFailed || sig.tooManyUnc; }

function fsUsage(mountpoint) {
  try {
    const st = fs.statfsSync(mountpoint);
    const total = st.blocks * st.bsize;
    const free  = st.bfree  * st.bsize;
    const avail = st.bavail * st.bsize;
    return { total: total, used: total - free, reserved: free - avail };
  } catch (e) {
    return { total: 0, used: 0, reserved: 0 };
  }
}

// True when the primary array currently carries an IDLE spare member.
// A 'spare' that is actively rebuilding into the array doesn't count —
// it is the repair in progress, not a spare on deck.
function hasHotSpare() {
  const primary = primaryArrayName();
  if (!primary) return false;
  const states = mdMemberStates(primary);
  return Object.keys(states).some(function (m) {
    return states[m].indexOf('spare') !== -1 &&
           !memberIsRebuilding(primary, m, states[m]);
  });
}

// Parity disks implied by a RAID level.
function parityCount(level) {
  return level === 'raid6' ? 2 : (level === 'raid5' ? 1 : 0);
}

// Union of present data disks and the primary array's members, so a disk
// pulled but still a faulty member keeps its bay. Each entry:
// { node, present, primaryRole } — primaryRole is the kernel md state.
function collectDisks() {
  const primary = primaryArrayName();
  const states = primary ? mdMemberStates(primary) : {};
  const map = new Map();
  for (const n of dataDisks()) {
    map.set(n, { node: n, present: true, primaryRole: '' });
  }
  if (primary) {
    for (const m of safeReaddir('/sys/block/' + primary + '/slaves')) {
      const p = parentDisk(m);
      if (!map.has(p)) {
        map.set(p, { node: p, present: fs.existsSync('/sys/class/block/' + p),
                     primaryRole: '' });
      }
      let role = states[m] || '';
      // Tag rebuilding members so the disk-state mappers can tell them
      // apart from idle spares — the raw kernel state says 'spare' either
      // way (see memberIsRebuilding).
      if (memberIsRebuilding(primary, m, role)) role = 'rebuilding,' + role;
      map.get(p).primaryRole = role;
    }
  }
  return [...map.values()].sort(function (a, b) {
    return a.node < b.node ? -1 : a.node > b.node ? 1 : 0;
  });
}

///////////////////////////////////////////////////////////////////////////////
// storage v1 — unifi.firmware.storage.v1.StorageAPI
///////////////////////////////////////////////////////////////////////////////

function buildV1() {
  let M;
  try {
    M = {
      api_pb:   require(PB1 + '/api_pb.js'),
      api_grpc: require(PB1 + '/api_grpc_pb.js'),
      disk_pb:  require(PB1 + '/disk_pb.js'),
      raid_pb:  require(PB1 + '/raid_pb.js'),
      space_pb: require(PB1 + '/space_pb.js'),
    };
  } catch (e) {
    return null;     // v1 protos not installed — skip the v1 service.
  }
  const { api_pb, api_grpc, disk_pb, raid_pb, space_pb } = M;

  // 'raid10' -> v1 RaidLevel. v1 has no value unifi-core accepts for "none"
  // (its mapper throws on RAID_LEVEL_UNSPECIFIED), so an absent level falls
  // back to RAID_LEVEL_1 — a harmless placeholder; the Raid message is only
  // ever attached when an array actually exists.
  function raidLevelEnum(s) {
    const R = raid_pb.RaidLevel;
    return ({
      raid1: R.RAID_LEVEL_1, raid5: R.RAID_LEVEL_5,
      raid6: R.RAID_LEVEL_6, raid10: R.RAID_LEVEL_10,
    })[s] || R.RAID_LEVEL_1;
  }

  // One Disk for a physical bay.
  function buildDisk(slot, node, present, primaryRole, sd) {
    const D = disk_pb;
    const disk = new D.Disk();
    disk.setSlot(slot);
    if (!present) {
      disk.setState(D.DiskState.DISK_STATE_FAULTY);
      return disk;
    }
    const table = (sd.ata_smart_attributes && sd.ata_smart_attributes.table) || [];
    const rotation = sd.rotation_rate || 0;
    const isHdd = rotation > 0;
    const sig = diskRiskSignals(sd);
    const reasons = [];
    if (sig.smartFailed) reasons.push('abnormal_smart');
    if (sig.tooManyUnc)  reasons.push('too_many_unc_count');

    const ss = new D.DiskSmartStatus();
    ss.setFailedSmartRequestCount(0);
    ss.setAtaSmartErrorLogCount(u32(
      sd.ata_smart_error_log && sd.ata_smart_error_log.summary &&
      sd.ata_smart_error_log.summary.count));
    ss.setTemperatureCelsius(u32(sd.temperature && sd.temperature.current));
    ss.setPowerOnHours(u32(sd.power_on_time && sd.power_on_time.hours));
    ss.setReadErrorRate(u32(attrRaw(table, 1)));
    ss.setUncorrectableSectorCount(u32(attrRaw(table, 198)));
    if (isHdd) ss.setHddBadSectorCount(u32(attrRaw(table, 5)));

    const info = new D.DiskInfo();
    info.setType(isHdd ? D.DiskType.DISK_TYPE_HDD : D.DiskType.DISK_TYPE_SSD);
    info.setName(node);
    info.setModel(sd.model_name || '');
    info.setSerial(sd.serial_number || '');
    info.setFirmware(sd.firmware_version || '');
    info.setAta((sd.ata_version  && sd.ata_version.string)  || '');
    info.setSata((sd.sata_version && sd.sata_version.string) || '');
    info.setSizeBytes((sd.user_capacity && sd.user_capacity.bytes) || deviceSizeBytes(node));
    info.setSmartStatus(ss);
    if (reasons.length) info.setAbnormalStateReasonsList(reasons);
    if (isHdd) info.setHddRpm(u32(rotation));

    disk.setState(
      reasons.length                            ? D.DiskState.DISK_STATE_AT_RISK   :
      primaryRole.indexOf('faulty')     !== -1  ? D.DiskState.DISK_STATE_FAULTY    :
      primaryRole.indexOf('rebuilding') !== -1  ? D.DiskState.DISK_STATE_REPAIRING :
      primaryRole.indexOf('spare')      !== -1  ? D.DiskState.DISK_STATE_SPARE     :
                                                  D.DiskState.DISK_STATE_NORMAL);
    disk.setInfo(info);
    return disk;
  }

  function buildDisks() {
    return collectDisks().map(function (d, i) {
      return buildDisk(i + 1, d.node, d.present, d.primaryRole,
                       d.present ? smart(d.node) : {});
    });
  }

  // SpaceRaidInfo for an md array — membership/topology.
  function buildSpaceRaidInfo(md) {
    const members = safeReaddir('/sys/block/' + md + '/slaves').sort();
    let expected = parseInt(readFile('/sys/block/' + md + '/md/raid_disks'), 10);
    if (!Number.isFinite(expected)) expected = members.length;
    const ri = new space_pb.SpaceRaidInfo();
    ri.setMemberNamesList(members);
    ri.setExpectedMemberCount(expected);
    // had_most = members actively in sync. A faulty/rebuilding member drops
    // this below expected; unifi-core derives had_most from
    // (maxConfigured vs expected) and surfaces a degraded array + the storage
    // notification when had_most < expected. Reporting expected here (the old
    // value) made every array look complete, so degradation never alerted.
    const inSyncCount = members.filter(function (m) {
      return (mdMemberStates(md)[m] || 'in_sync').indexOf('in_sync') !== -1;
    }).length;
    ri.setMaxConfiguredMemberCount(inSyncCount);
    ri.setMemberSize(members.length ? deviceSizeBytes(members[0]) : 0);
    return { raidInfo: ri, members: members };
  }

  // SpaceState + SpaceHealthState for an md array.
  function mdSpaceState(md, members) {
    const S = space_pb;
    const sync = mdSyncState(md);
    const states = mdMemberStates(md);
    const allInSync = members.every(function (m) {
      return (states[m] || 'in_sync').indexOf('in_sync') !== -1;
    });
    // mdadm 'recover' rebuilds a missing member onto a degraded array —
    // that is a REPAIR (restoring redundancy), not a benign 'resync'. The
    // console renders SYNCING as "fully operational" but REPAIRING as an
    // active repair, which is what a degraded rebuild should read as.
    const rebuilding = sync.action === 'recover';
    let state = S.SpaceState.SPACE_STATE_NONE;
    if (sync.action === 'recover' || sync.action === 'check' ||
        sync.action === 'repair') {
      state = S.SpaceState.SPACE_STATE_REPAIRING;
    } else if (sync.action === 'resync') {
      state = S.SpaceState.SPACE_STATE_SYNCING;
    } else if (sync.action === 'reshape') {
      state = S.SpaceState.SPACE_STATE_EXPANDING;
    }
    const degraded = sync.degraded || !allInSync;
    const health = degraded
      ? S.SpaceHealthState.SPACE_HEALTH_STATE_AT_RISK
      : S.SpaceHealthState.SPACE_HEALTH_STATE_HEALTHY;
    // Surface the SPACE_DEGRADED problem (which the console renders as
    // "please reinstall this hard drive") ONLY when the array is degraded
    // and NOT actively rebuilding. While a member rebuilds, the drive is
    // present and resyncing — the REPAIRING state + progress convey that, and
    // a "reinstall the drive" prompt would be wrong. When degraded with no
    // rebuild running (a member is truly gone), the reinstall prompt is right.
    const problems = [];
    if (degraded && !rebuilding) {
      const p = new S.SpaceHealthProblem();
      p.setType(S.SpaceHealthProblemType.SPACE_HEALTH_PROBLEM_TYPE_SPACE_DEGRADED);
      p.setLevel(S.SpaceHealthProblemLevel.SPACE_HEALTH_PROBLEM_LEVEL_AT_RISK);
      problems.push(p);
    }
    return { state: state, health: health, pct: sync.pct, problems: problems };
  }

  function buildSpaces() {
    const S = space_pb;
    const primary = primaryArrayName() || baseName(volumeDevice(STORAGE_VOLUME));
    const spaces = [];

    if (primary) {
      const u = fsUsage(STORAGE_VOLUME);
      const info = new S.SpaceInfo();
      info.setType(S.SpaceType.SPACE_TYPE_PRIMARY);
      info.setTotalBytes(u.total);
      info.setUsedBytes(u.used);
      info.setSystemReservedBytes(u.reserved);
      if (primary.startsWith('md')) {
        const r = buildSpaceRaidInfo(primary);
        const st = mdSpaceState(primary, r.members);
        info.setState(st.state);
        info.setHealthState(st.health);
        if (st.problems.length) info.setHealthProblemsList(st.problems);
        if (st.pct > 0 && st.pct < 100) info.setActionProgressPercent(st.pct);
        info.setRaidMemberInfo(r.raidInfo);
      } else {
        info.setState(S.SpaceState.SPACE_STATE_NONE);
        info.setHealthState(S.SpaceHealthState.SPACE_HEALTH_STATE_HEALTHY);
      }
      const ext4 = new S.Ext4SpecificInfo();
      ext4.setErrorCount(0);
      ext4.setExpansionLimitBytes(0);
      info.setExt4SpecificInfo(ext4);

      const sp = new S.Space();
      sp.setDevice(primary);
      sp.setDeleted(false);
      sp.setInfo(info);
      spaces.push(sp);
    }

    safeReaddir('/sys/block').sort().forEach(function (name) {
      if (name.indexOf('md') !== 0 || name === primary) return;
      if (!safeReaddir('/sys/block/' + name + '/slaves').length) return;
      const r = buildSpaceRaidInfo(name);
      const st = mdSpaceState(name, r.members);
      const info = new S.SpaceInfo();
      info.setType(S.SpaceType.SPACE_TYPE_SWAP);
      info.setState(st.state);
      info.setHealthState(st.health);
      if (st.pct > 0 && st.pct < 100) info.setActionProgressPercent(st.pct);
      info.setRaidMemberInfo(r.raidInfo);
      const sp = new S.Space();
      sp.setDevice(name);
      sp.setDeleted(false);
      sp.setInfo(info);
      spaces.push(sp);
    });

    const rootDev = baseName(volumeDevice('/'));
    const u = fsUsage('/');
    const rootInfo = new S.SpaceInfo();
    rootInfo.setType(S.SpaceType.SPACE_TYPE_ROOT);
    rootInfo.setTotalBytes(u.total);
    rootInfo.setUsedBytes(u.used);
    rootInfo.setSystemReservedBytes(u.reserved);
    rootInfo.setState(S.SpaceState.SPACE_STATE_NONE);
    rootInfo.setHealthState(S.SpaceHealthState.SPACE_HEALTH_STATE_HEALTHY);
    const rootExt4 = new S.Ext4SpecificInfo();
    rootExt4.setErrorCount(0);
    rootExt4.setExpansionLimitBytes(0);
    rootInfo.setExt4SpecificInfo(rootExt4);
    const rootSp = new S.Space();
    rootSp.setDevice(rootDev || 'root');
    rootSp.setDeleted(false);
    rootSp.setInfo(rootInfo);
    spaces.push(rootSp);

    return spaces;
  }

  function buildRaid() {
    const primary = primaryArrayName();
    const level = raidLevelEnum(primary
      ? readFile('/sys/block/' + primary + '/md/level')
      : '');
    const raid = new raid_pb.Raid();
    raid.setRaidLevel(level);
    raid.setUseRaidHotSpare(boolValue(hasHotSpare()));
    return raid;
  }

  // Response factories.
  function diskStateResponse() {
    const r = new api_pb.DiskStateResponse();
    r.setDiskList(buildDisks());
    return r;
  }
  function spaceStateResponse() {
    const r = new api_pb.SpaceStateResponse();
    r.setSpaceList(buildSpaces());
    return r;
  }
  // The Raid message is attached ONLY when a live array exists. unifi-core's
  // RaidState / StorageSettings handlers both early-return on !hasRaid(), so
  // an unset Raid means "no RAID configured" — that is what makes the setup
  // UI prompt for a storage configuration.
  function raidStateResponse() {
    const r = new api_pb.RaidStateResponse();
    if (primaryArrayName() !== '') r.setRaid(buildRaid());
    return r;
  }
  function storageSettingsResponse() {
    const r = new api_pb.StorageSettingsResponse();
    if (primaryArrayName() !== '') {
      r.setRaid(buildRaid());
      r.setIsConfigured(boolValue(true));
    }
    return r;
  }
  function flashStateResponse()  { return new api_pb.FlashStateResponse(); }
  function sdCardStateResponse() { return new api_pb.SDCardStateResponse(); }

  return {
    label: 'v1',
    service: api_grpc.StorageAPIService,
    impl: {
      diskState:       streamer('v1/DiskState',       diskStateResponse),
      flashState:      streamer('v1/FlashState',      flashStateResponse),
      sDCardState:     streamer('v1/SDCardState',     sdCardStateResponse),
      spaceState:      streamer('v1/SpaceState',      spaceStateResponse),
      raidState:       streamer('v1/RaidState',       raidStateResponse),
      storageSettings: streamer('v1/StorageSettings', storageSettingsResponse),
    },
  };
}

///////////////////////////////////////////////////////////////////////////////
// storage v2 — unifi.firmware.storage.v2.StorageAPI
///////////////////////////////////////////////////////////////////////////////

function buildV2() {
  let M;
  try {
    M = {
      api_pb:   require(PB2 + '/api_pb.js'),
      api_grpc: require(PB2 + '/api_grpc_pb.js'),
      slot_pb:  require(PB2 + '/slot_pb.js'),
      disk_pb:  require(PB2 + '/disk_pb.js'),
      dev_pb:   require(PB2 + '/device_pb.js'),
      space_pb: require(PB2 + '/space_pb.js'),
      fsys_pb:  require(PB2 + '/filesystem_pb.js'),
      raid_pb:  require(PB2 + '/raid_pb.js'),
      set_pb:   require(PB2 + '/setting_pb.js'),
    };
  } catch (e) {
    return null;     // v2 protos not installed — skip the v2 service.
  }
  const { api_pb, api_grpc, slot_pb, disk_pb, dev_pb,
          space_pb, fsys_pb, raid_pb, set_pb } = M;

  function raidLevelEnum(s) {
    const R = raid_pb.RaidLevel;
    return ({
      raid0: R.RAID_LEVEL_0,  raid1: R.RAID_LEVEL_1,
      raid5: R.RAID_LEVEL_5,  raid6: R.RAID_LEVEL_6,
      raid10: R.RAID_LEVEL_10,
    })[s] || R.RAID_LEVEL_UNSPECIFIED;
  }

  function sectorFormat(sd) {
    const F = disk_pb.DiskSectorFormat;
    const lb = Number(sd.logical_block_size)  || 0;
    const pb = Number(sd.physical_block_size) || 0;
    if (lb === 4096) return F.DISK_SECTOR_FORMAT_4KN;
    if (lb === 512 && pb === 4096) return F.DISK_SECTOR_FORMAT_512E;
    if (lb === 512 && pb === 512)  return F.DISK_SECTOR_FORMAT_512N;
    return F.DISK_SECTOR_FORMAT_UNSPECIFIED;
  }

  function buildDiskInfo(node, primaryRole, sd) {
    const D = disk_pb;
    const info = new D.DiskInfo();
    const table = (sd.ata_smart_attributes && sd.ata_smart_attributes.table) || [];
    const rotation = sd.rotation_rate || 0;
    const isHdd  = rotation > 0;
    const isNvme = /^nvme/.test(node);
    const sig = diskRiskSignals(sd);

    const si = new D.DiskSmartInfo();
    si.setType(isHdd ? D.DiskType.DISK_TYPE_HDD : D.DiskType.DISK_TYPE_SSD);
    si.setProtocol(isNvme ? D.DiskProtocol.DISK_PROTOCOL_NVME
                          : D.DiskProtocol.DISK_PROTOCOL_SATA);
    si.setModel(sd.model_name || '');
    si.setSerial(sd.serial_number || '');
    si.setFirmware(sd.firmware_version || '');
    si.setSectorFormat(sectorFormat(sd));
    si.setSizeBytes((sd.user_capacity && sd.user_capacity.bytes) || deviceSizeBytes(node));
    if (isHdd) {
      const hdd = new D.DiskSmartInfoHDD();
      hdd.setRpm(u32(rotation));
      si.setHdd(hdd);
    } else {
      si.setSsd(new D.DiskSmartInfoSSD());
    }
    if (isNvme) {
      const nv = new D.DiskSmartInfoNVME();
      nv.setVersion((sd.nvme_version && sd.nvme_version.string) || '');
      si.setNvme(nv);
    } else {
      const sata = new D.DiskSmartInfoSATA();
      sata.setVersion((sd.sata_version && sd.sata_version.string) || '');
      sata.setAtaVersion((sd.ata_version && sd.ata_version.string) || '');
      si.setSata(sata);
    }
    info.setSmartInfo(si);

    const sa = new D.DiskSmartAttr();
    const status = sd.smart_status || {};
    sa.setSmartSelfAssessment(('passed' in status) ? !!status.passed : true);
    sa.setTemperatureCelsius(u32(sd.temperature && sd.temperature.current));
    sa.setPowerOnHours(u32(sd.power_on_time && sd.power_on_time.hours));
    sa.setFailedSmartRequestCount(0);
    sa.setSmartErrorLogCount(u32(
      sd.ata_smart_error_log && sd.ata_smart_error_log.summary &&
      sd.ata_smart_error_log.summary.count));
    sa.setReadErrorRate(u32(attrRaw(table, 1)));
    sa.setUncorrectableSectorCount(u32(attrRaw(table, 198)));
    if (isHdd) {
      const h = new D.DiskSmartAttrHDD();
      h.setBadSectorCount(u32(attrRaw(table, 5)));
      sa.setHdd(h);
    } else {
      const s = new D.DiskSmartAttrSSD();
      s.setLifespanPercent(100);
      sa.setSsd(s);
    }
    if (isNvme) {
      sa.setNvme(new D.DiskSmartAttrNVME());
    } else {
      const st = new D.DiskSmartAttrSATA();
      st.setVersion((sd.sata_version && sd.sata_version.string) || '');
      sa.setSata(st);
    }
    info.setSmartAttr(sa);

    info.setRaidState(
      primaryRole.indexOf('faulty')     !== -1 ? D.DiskRaidState.DISK_RAID_STATE_FAULTY :
      primaryRole.indexOf('rebuilding') !== -1 ? D.DiskRaidState.DISK_RAID_STATE_REPAIRING :
      primaryRole.indexOf('spare')      !== -1 ? D.DiskRaidState.DISK_RAID_STATE_LOCAL_SPARE :
      primaryRole.indexOf('in_sync')    !== -1 ? D.DiskRaidState.DISK_RAID_STATE_ACTIVE :
                                                 D.DiskRaidState.DISK_RAID_STATE_NOT_IN_RAID);

    const ab = new D.DiskAbnormalInfo();
    const reasons = [];
    if (sig.smartFailed) reasons.push(D.DiskRiskReason.DISK_RISK_REASON_SMART_CHECK_FAILED);
    if (sig.tooManyUnc)  reasons.push(D.DiskRiskReason.DISK_RISK_REASON_TOO_MANY_UNCORRECTABLE_SECTORS);
    if (reasons.length) ab.setRiskReasonsList(reasons);
    info.setAbnormalInfo(ab);

    info.setAssignmentState(primaryRole
      ? D.DiskAssignmentState.DISK_ASSIGNMENT_STATE_ASSIGNED
      : D.DiskAssignmentState.DISK_ASSIGNMENT_STATE_UNASSIGNED);
    return info;
  }

  function buildDisk(node, primaryRole, sd) {
    const disk = new disk_pb.Disk();
    disk.setDevice(node);
    disk.setStatus(
      primaryRole.indexOf('faulty') !== -1 ? dev_pb.DeviceHealthStatus.DEVICE_HEALTH_STATUS_BROKEN :
      anyRisk(diskRiskSignals(sd))         ? dev_pb.DeviceHealthStatus.DEVICE_HEALTH_STATUS_AT_RISK :
                                             dev_pb.DeviceHealthStatus.DEVICE_HEALTH_STATUS_HEALTHY);
    disk.setInfo(buildDiskInfo(node, primaryRole, sd));
    const ident = new dev_pb.DeviceIdentifier();
    ident.setById(sd.serial_number || node);
    disk.setIdentifier(ident);
    return disk;
  }

  function buildSlotDisk(index, node, present, primaryRole, sd) {
    const slot = new slot_pb.SlotDisk();
    slot.setIndex(index);
    if (!present) {
      slot.setState(primaryRole
        ? slot_pb.SlotState.SLOT_STATE_BROKEN
        : slot_pb.SlotState.SLOT_STATE_EMPTY_SLOT);
      return slot;
    }
    slot.setState(slot_pb.SlotState.SLOT_STATE_PRESENT);
    slot.setDisk(buildDisk(node, primaryRole, sd));
    return slot;
  }

  function buildSlotDisks() {
    return collectDisks().map(function (d, i) {
      return buildSlotDisk(i + 1, d.node, d.present, d.primaryRole,
                           d.present ? smart(d.node) : {});
    });
  }

  function buildRaid(md) {
    const members = safeReaddir('/sys/block/' + md + '/slaves').sort();
    const states = mdMemberStates(md);
    const sync = mdSyncState(md);
    const level = readFile('/sys/block/' + md + '/md/level');
    let expected = parseInt(readFile('/sys/block/' + md + '/md/raid_disks'), 10);
    if (!Number.isFinite(expected)) expected = members.length;
    // Idle spares only — a member rebuilding into the array reports the
    // kernel state 'spare' too, but counting it here turns into
    // hotspare:true upstream while the array is degraded and repairing.
    const spares = Object.keys(states).filter(function (m) {
      return states[m].indexOf('spare') !== -1 &&
             !memberIsRebuilding(md, m, states[m]);
    }).length;

    const R = raid_pb;
    const lvl = raidLevelEnum(level);
    const info = new R.RaidInfo();
    info.setUuid(readFile('/sys/block/' + md + '/md/uuid'));
    // mdadm 'recover' rebuilds a missing member onto a degraded array —
    // that is a REPAIR (restoring redundancy), not a benign 'resync'.
    // Same reasoning as the v1 space state: the console renders SYNCING
    // as routine background work but REPAIRING as an active repair.
    info.setSyncAction(
      sync.action === 'resync'                              ? R.RaidSyncAction.RAID_SYNC_ACTION_SYNCING :
      sync.action === 'recover' || sync.action === 'repair' ? R.RaidSyncAction.RAID_SYNC_ACTION_REPAIRING :
      sync.action === 'reshape'                             ? R.RaidSyncAction.RAID_SYNC_ACTION_EXPANDING :
      sync.action === 'check'                               ? R.RaidSyncAction.RAID_SYNC_ACTION_CHECKING :
                                                              R.RaidSyncAction.RAID_SYNC_ACTION_NONE);
    info.setCurrentLevel(lvl);
    info.setConfiguredLevel(lvl);
    info.setExpectedParityCount(parityCount(level));
    info.setSizeKilobytes(u32(deviceSizeBytes(md) / 1024));
    if (sync.pct > 0 && sync.pct < 100) info.setActionProgressPercent(sync.pct);

    const mi = new R.RaidMemberInfo();
    mi.setSize(members.length ? deviceSizeBytes(members[0]) : 0);
    mi.setNamesList(members);
    mi.setExpectedCount(expected);
    mi.setMaxConfiguredCount(expected);
    mi.setParityCount(parityCount(level));
    mi.setSpareCount(spares);

    const raid = new R.Raid();
    raid.setDevice(md);
    raid.setState(sync.degraded ? R.RaidState.RAID_STATE_DEGRADED
                                : R.RaidState.RAID_STATE_HEALTHY);
    raid.setInfo(info);
    raid.setMembers(mi);
    return raid;
  }

  function buildFilesystem(device, mountpoint, type) {
    const F = fsys_pb;
    const u = fsUsage(mountpoint);
    const fsi = new F.FilesystemInfo();
    fsi.setUuid('');
    fsi.setType(type);
    fsi.setMountPoint(mountpoint);
    fsi.setMountStatus(F.FilesystemMountStatus.FILESYSTEM_MOUNT_STATUS_MOUNTED);
    fsi.setTotalBytes(u.total);
    fsi.setUsedBytes(u.used);
    fsi.setSystemReservedBytes(u.reserved);
    if (type === F.FilesystemType.FILESYSTEM_TYPE_EXT4) {
      const ext4 = new F.Ext4SpecificInfo();
      ext4.setErrorCount(0);
      ext4.setExpansionLimitBytes(0);
      fsi.setExt4(ext4);
    }
    return fsi;
  }

  function buildSpaces() {
    const S = space_pb;
    const F = fsys_pb;
    const primary = primaryArrayName();
    const spaces = [];

    if (primary) {
      const sync = mdSyncState(primary);
      const info = new S.SpaceInfo();
      info.setFilesystem(buildFilesystem(primary, STORAGE_VOLUME,
                                         F.FilesystemType.FILESYSTEM_TYPE_EXT4));
      info.setRaidList([buildRaid(primary)]);
      // Degraded array -> attach the SPACE_DEGRADED issue (the reason) so
      // the console Storage UI surfaces a degraded/at-risk warning, not just
      // the benign syncing state. Mirrors the v1 SpaceHealthProblem.
      if (sync.degraded && sync.action !== 'recover') {
        const issue = new S.SpaceIssue();
        issue.setType(S.SpaceIssueType.SPACE_ISSUE_TYPE_SPACE_DEGRADED);
        issue.setSeverity(S.SpaceIssueSeverity.SPACE_ISSUE_SEVERITY_AT_RISK);
        info.setIssuesList([issue]);
      }
      const sp = new S.Space();
      sp.setDevice(primary);
      sp.setType(S.SpaceType.SPACE_TYPE_DATA);
      // A degraded array reports AT_RISK even while a member is actively
      // rebuilding. Protect 7.1's dashboard knows exactly three storage
      // presentations, all keyed off the blob health unifi-core derives
      // from this state: "health" renders the normal usage tile, "atrisk"
      // renders an accurate "At Risk" label (with a sloppy "reinstall this
      // hard drive" HOVER tooltip — its chooser has no repairing branch),
      // and NO health (what SCANNING maps to) renders a blank tile, hiding
      // the rebuild entirely. AT_RISK is the least-wrong of the three; the
      // honest repairing view lives on the storage details page, fed by
      // the raid DEGRADED/REPAIRING state and the member's REPAIRING state.
      sp.setState(
        sync.degraded                                      ? S.SpaceState.SPACE_STATE_AT_RISK :
        (sync.action === 'resync' || sync.action === 'recover' ||
         sync.action === 'check'  || sync.action === 'repair') ? S.SpaceState.SPACE_STATE_SCANNING :
                                                              S.SpaceState.SPACE_STATE_HEALTHY);
      sp.setInfo(info);
      spaces.push(sp);
    }

    safeReaddir('/sys/block').sort().forEach(function (name) {
      if (name.indexOf('md') !== 0 || name === primary) return;
      if (!safeReaddir('/sys/block/' + name + '/slaves').length) return;
      const info = new S.SpaceInfo();
      info.setRaidList([buildRaid(name)]);
      const sp = new S.Space();
      sp.setDevice(name);
      sp.setType(S.SpaceType.SPACE_TYPE_SWAP);
      sp.setState(S.SpaceState.SPACE_STATE_HEALTHY);
      sp.setInfo(info);
      spaces.push(sp);
    });

    const rootDev = baseName(volumeDevice('/'));
    const rootInfo = new S.SpaceInfo();
    rootInfo.setFilesystem(buildFilesystem(rootDev, '/',
                                           F.FilesystemType.FILESYSTEM_TYPE_EXT4));
    const rootSp = new S.Space();
    rootSp.setDevice(rootDev || 'root');
    rootSp.setType(S.SpaceType.SPACE_TYPE_ROOT);
    rootSp.setState(S.SpaceState.SPACE_STATE_HEALTHY);
    rootSp.setInfo(rootInfo);
    spaces.push(rootSp);

    return spaces;
  }

  function buildStorageSetting() {
    const primary = primaryArrayName();
    if (!primary) return null;
    const raidSetting = new set_pb.RaidSetting();
    raidSetting.setLevel(raidLevelEnum(readFile('/sys/block/' + primary + '/md/level')));
    raidSetting.setUseRaidHotSpare(boolValue(hasHotSpare()));
    const global = new set_pb.GlobalSetting();
    global.setRaid(raidSetting);
    const setting = new set_pb.StorageSetting();
    setting.setMode(set_pb.StorageSettingMode.STORAGE_SETTING_MODE_GLOBAL_SETTING);
    setting.setGlobal(global);
    return setting;
  }

  function diskStateResponse() {
    const r = new api_pb.DiskStateResponse();
    r.setSlotList(buildSlotDisks());
    return r;
  }
  function spaceStateResponse() {
    const r = new api_pb.SpaceStateResponse();
    r.setSpaceList(buildSpaces());
    return r;
  }
  function storageSettingsResponse() {
    const r = new api_pb.StorageSettingsResponse();
    const setting = buildStorageSetting();
    if (setting) r.setSetting(setting);
    return r;
  }
  function flashStateResponse()     { return new api_pb.FlashStateResponse(); }
  function sdCardStateResponse()    { return new api_pb.SDCardStateResponse(); }
  function cacheSlotStateResponse() { return new api_pb.CacheSlotStateResponse(); }

  return {
    label: 'v2',
    service: api_grpc.StorageAPIService,
    impl: {
      diskState:       streamer('v2/DiskState',       diskStateResponse),
      sDCardState:     streamer('v2/SDCardState',      sdCardStateResponse),
      flashState:      streamer('v2/FlashState',       flashStateResponse),
      cacheSlotState:  streamer('v2/CacheSlotState',   cacheSlotStateResponse),
      spaceState:      streamer('v2/SpaceState',       spaceStateResponse),
      storageSettings: streamer('v2/StorageSettings',  storageSettingsResponse),
    },
  };
}

///////////////////////////////////////////////////////////////////////////////
// gRPC server — server-streaming: emit a snapshot, then re-emit every POLL_MS
///////////////////////////////////////////////////////////////////////////////

function streamer(name, build) {
  return function (call) {
    log(name + ': subscriber connected');
    let timer = null;
    const push = function () {
      let resp;
      try {
        resp = build();
      } catch (e) {
        log(name + ': build failed: ' + (e && e.stack || e));
        return;
      }
      try { call.write(resp); } catch (e) { /* stream closed */ }
    };
    const stop = function () {
      if (timer) { clearInterval(timer); timer = null; }
      log(name + ': subscriber gone');
    };
    push();
    timer = setInterval(push, POLL_MS);
    call.on('cancelled', stop);
    call.on('error', stop);
    call.on('close', stop);
  };
}

function main() {
  const versions = [buildV1(), buildV2()].filter(Boolean);
  if (!versions.length) {
    log('no storage protobuf modules found under ' + NM +
        '/@ubnt/unifi-protobufs — cannot serve any StorageAPI');
    process.exit(1);
  }

  const server = new grpc.Server();
  for (const v of versions) {
    server.addService(v.service, v.impl);
  }
  const served = versions.map(function (v) { return v.label; }).join(' + ');

  server.bindAsync(LISTEN, grpc.ServerCredentials.createInsecure(), function (err) {
    if (err) {
      log('could not bind ' + LISTEN + ': ' + err.message +
          ' — is ustated still up? (systemctl mask ustated && systemctl stop ustated)');
      process.exit(1);
    }
    log('listening on ' + LISTEN +
        ' — unifi.firmware.storage StorageAPI (' + served + ')');
  });

  function shutdown() {
    log('shutting down');
    server.tryShutdown(function () { process.exit(0); });
    setTimeout(function () { process.exit(0); }, 2000);
  }
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main();
