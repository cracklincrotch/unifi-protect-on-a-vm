#!/usr/bin/env node24
'use strict';
/******************************************************************************
 * ustated-shim.js — storage/v1 gRPC replacement for the Protect VM.
 *
 * WHY
 *
 * unifi-core renders its Storage panel from `nvr.systemInfo.ustorage`
 * (disks, raid, spaces). On a real UNVR that data path is:
 *
 *     usd  (:10055, console.event.v1.ConsoleEventAPI)
 *       -> ustated  (translates to unifi.firmware.storage.v1)
 *       -> unifi-core  (subscribes to ustated on 127.0.0.1:11052)
 *
 * On this VM `usd` cannot run. `usd-shim.py` stood in for it on :10055 and
 * `ustated` consumed that — but `ustated` silently failed to translate the
 * shim's events into the storage model unifi-core reads, so `disks`/`raid`
 * stayed empty and the Storage panel spun forever. `ustated` is a closed Go
 * binary with no debug output, so fixing the translation blind is not
 * feasible.
 *
 * This shim removes `ustated` from the path: it serves
 * `unifi.firmware.storage.v1.StorageAPI` — the exact gRPC API unifi-core
 * subscribes to — directly on :11052.
 *
 * It is built on Ubiquiti's own generated protobuf + gRPC modules, loaded
 * straight from unifi-core's node_modules, so the wire format and service
 * definition are exact. The service/method paths were confirmed by tracing
 * unifi-core's own calls (GRPC_TRACE=all): it requests
 *   /unifi.firmware.storage.v1.StorageAPI/{DiskState,RaidState,SpaceState,
 *                                         StorageSettings}.
 *
 * DISK FAILURE DETECTION — TWO MODES
 *
 *   Mode A — SMART degradation: disk reachable but fails self-assessment.
 *            Detected via smartctl -> Disk.state = AT_RISK.
 *   Mode B — disk drops off the bus: md marks the member `faulty`; smartctl
 *            can't read it. Detected via md member state in /sys ->
 *            Disk.state = FAULTY.
 *   A disk is reported failed if EITHER signal fires.
 *
 * REQUIRES
 *
 *   - node24 (on PATH)
 *   - unifi-core's node_modules at the path below (grpc-js + the
 *     @ubnt/unifi-protobufs storage/v1 modules) — present on any
 *     unifi-core install.
 *   - smartctl at /usr/sbin/smartctl (the proxy wrapper, for real SMART).
 *   - `ustated` masked + stopped so :11052 is free. `ustated` is the
 *     "UI State Exporter"; if non-storage UI misbehaves with it down,
 *     revert: systemctl unmask ustated && systemctl start ustated.
 *
 * INSTALL (inside the VM, as root)
 *
 * For the permanent install see ustated-shim.service and the "Storage
 * health" section of the README. To run it by hand for testing:
 *
 *   systemctl mask ustated
 *   systemctl stop ustated            # frees 127.0.0.1:11052
 *   node24 ustated-shim.js            # foreground; watch stderr
 ******************************************************************************/

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// unifi-core's node_modules — grpc-js + generated protobuf/gRPC modules.
// Loading by absolute path lets this file live anywhere; the modules' own
// relative + bare requires still resolve from inside that tree.
const NM = '/usr/share/unifi-core/app/node_modules';
const PB = NM + '/@ubnt/unifi-protobufs/unifi/firmware/storage/v1';

const grpc     = require(NM + '/@grpc/grpc-js');
const wrappers = require(NM + '/google-protobuf/google/protobuf/wrappers_pb.js');
const api_pb   = require(PB + '/api_pb.js');
const api_grpc = require(PB + '/api_grpc_pb.js');
const disk_pb  = require(PB + '/disk_pb.js');
const flash_pb = require(PB + '/flash_pb.js');
const raid_pb  = require(PB + '/raid_pb.js');
const sd_pb    = require(PB + '/sdcard_pb.js');
const space_pb = require(PB + '/space_pb.js');

const LISTEN         = '127.0.0.1:11052';
const STORAGE_VOLUME = '/volume1';
const SMARTCTL       = '/usr/sbin/smartctl';
const POLL_MS        = 30000;          // re-stream interval
const SMART_TIMEOUT  = 20000;          // hard ceiling per smartctl call
const U32_MAX        = 4294967295;

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
// Storage inspection — /sys, /proc, smartctl
///////////////////////////////////////////////////////////////////////////////

function readFile(p) {
  try { return fs.readFileSync(p, 'utf8').trim(); } catch (e) { return ''; }
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

// A partition (sde5) has a 'partition' attr in sysfs; its parent whole disk
// is the directory above it. A whole disk resolves to itself.
function parentDisk(node) {
  if (fs.existsSync('/sys/class/block/' + node + '/partition')) {
    return baseName(path.dirname(fs.realpathSync('/sys/class/block/' + node)));
  }
  return node;
}

// md member basename -> kernel md state ('in_sync', 'faulty', ...).
function mdMemberStates(md) {
  const states = {};
  const base = '/sys/block/' + md + '/md';
  try {
    for (const e of fs.readdirSync(base)) {
      if (e.startsWith('dev-')) states[e.slice(4)] = readFile(base + '/' + e + '/state');
    }
  } catch (e) {}
  return states;
}

// [{disk, member, state}] for every physical disk backing /volume1.
function physicalDisks() {
  const name = baseName(volumeDevice(STORAGE_VOLUME));
  let members = [];
  if (name.startsWith('md')) {
    try { members = fs.readdirSync('/sys/block/' + name + '/slaves').sort(); } catch (e) {}
  }
  const states = mdMemberStates(name);
  const out = [], seen = new Set();
  for (const m of members) {
    const disk = parentDisk(m);
    if (disk && !seen.has(disk)) {
      seen.add(disk);
      out.push({ disk: disk, member: m, state: states[m] || '' });
    }
  }
  return out;
}

// Parsed `smartctl --json -x`; {} on any failure. smartctl's exit status is
// a bitmask (non-zero when the disk reports problems, or can't be opened),
// so a thrown error still carries valid JSON on stdout.
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

function deviceSizeBytes(node) {
  const sectors = parseInt(readFile('/sys/class/block/' + node + '/size'), 10);
  return Number.isFinite(sectors) ? sectors * 512 : 0;
}

// 'raid10' -> RaidLevel enum (v1 numbering: 5=1, 10=2, 1=3, 6=4).
function raidLevelEnum(s) {
  const R = raid_pb.RaidLevel;
  return ({
    raid1: R.RAID_LEVEL_1, raid5: R.RAID_LEVEL_5,
    raid6: R.RAID_LEVEL_6, raid10: R.RAID_LEVEL_10,
  })[s] || R.RAID_LEVEL_UNSPECIFIED;
}

///////////////////////////////////////////////////////////////////////////////
// Protobuf message builders — unifi.firmware.storage.v1
///////////////////////////////////////////////////////////////////////////////

// One Disk for a physical bay.
function buildDisk(slot, node, memberState, sd) {
  const D = disk_pb;
  const table  = (sd.ata_smart_attributes && sd.ata_smart_attributes.table) || [];
  const status = sd.smart_status || {};
  const mdFaulty    = memberState.indexOf('faulty') !== -1;
  const smartFailed = ('passed' in status) && status.passed === false;
  const rotation = sd.rotation_rate || 0;
  const isHdd = rotation > 0;

  const smartStatus = new D.DiskSmartStatus();
  smartStatus.setFailedSmartRequestCount(0);
  smartStatus.setAtaSmartErrorLogCount(u32(
    sd.ata_smart_error_log && sd.ata_smart_error_log.summary &&
    sd.ata_smart_error_log.summary.count));
  smartStatus.setTemperatureCelsius(u32(sd.temperature && sd.temperature.current));
  smartStatus.setPowerOnHours(u32(sd.power_on_time && sd.power_on_time.hours));
  smartStatus.setReadErrorRate(u32(attrRaw(table, 1)));             // Raw_Read_Error_Rate
  smartStatus.setUncorrectableSectorCount(u32(attrRaw(table, 198)));// Offline_Uncorrectable
  if (isHdd) smartStatus.setHddBadSectorCount(u32(attrRaw(table, 5))); // Reallocated_Sector_Ct

  const info = new D.DiskInfo();
  info.setType(isHdd ? D.DiskType.DISK_TYPE_HDD : D.DiskType.DISK_TYPE_SSD);
  info.setName(node);
  info.setModel(sd.model_name || '');
  info.setSerial(sd.serial_number || '');
  info.setFirmware(sd.firmware_version || '');
  info.setAta((sd.ata_version  && sd.ata_version.string)  || '');
  info.setSata((sd.sata_version && sd.sata_version.string) || '');
  info.setSizeBytes((sd.user_capacity && sd.user_capacity.bytes) || deviceSizeBytes(node));
  info.setSmartStatus(smartStatus);
  if (isHdd) info.setHddRpm(u32(rotation));

  const disk = new D.Disk();
  disk.setSlot(slot);
  disk.setState(
    mdFaulty    ? D.DiskState.DISK_STATE_FAULTY  :
    smartFailed ? D.DiskState.DISK_STATE_AT_RISK :
                  D.DiskState.DISK_STATE_NORMAL);
  disk.setInfo(info);
  return disk;
}

// DiskState response — one Disk per physical bay.
function buildDisks() {
  return physicalDisks().map(function (d, i) {
    return buildDisk(i + 1, d.disk, d.state, smart(d.disk));
  });
}

// SpaceRaidInfo for an md array — membership/topology (level lives in Raid).
function buildSpaceRaidInfo(md) {
  let members = [];
  try { members = fs.readdirSync('/sys/block/' + md + '/slaves').sort(); } catch (e) {}
  let expected = parseInt(readFile('/sys/block/' + md + '/md/raid_disks'), 10);
  if (!Number.isFinite(expected)) expected = members.length;
  const ri = new space_pb.SpaceRaidInfo();
  ri.setMemberNamesList(members);
  ri.setExpectedMemberCount(expected);
  ri.setMaxConfiguredMemberCount(expected);
  ri.setMemberSize(members.length ? deviceSizeBytes(members[0]) : 0);
  return { raidInfo: ri, members: members, expected: expected };
}

// md array health: HEALTHY when every member is in_sync, else AT_RISK.
function mdHealthy(md, members) {
  const states = mdMemberStates(md);
  return members.every(function (m) {
    return (states[m] || 'in_sync').indexOf('in_sync') !== -1;
  });
}

// SpaceState response — primary (md3), swap md arrays, root.
function buildSpaces() {
  const S = space_pb;
  const primary = baseName(volumeDevice(STORAGE_VOLUME));
  const spaces = [];

  // Primary recording volume.
  if (primary) {
    const u = fsUsage(STORAGE_VOLUME);
    const info = new S.SpaceInfo();
    info.setType(S.SpaceType.SPACE_TYPE_PRIMARY);
    info.setTotalBytes(u.total);
    info.setUsedBytes(u.used);
    info.setSystemReservedBytes(u.reserved);
    info.setState(S.SpaceState.SPACE_STATE_NONE);
    if (primary.startsWith('md')) {
      const r = buildSpaceRaidInfo(primary);
      info.setRaidMemberInfo(r.raidInfo);
      info.setHealthState(mdHealthy(primary, r.members)
        ? S.SpaceHealthState.SPACE_HEALTH_STATE_HEALTHY
        : S.SpaceHealthState.SPACE_HEALTH_STATE_AT_RISK);
    } else {
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

  // Other md arrays = swap (the migrated UNVR swap array).
  let blocks = [];
  try { blocks = fs.readdirSync('/sys/block'); } catch (e) {}
  blocks.sort().forEach(function (name) {
    if (name.indexOf('md') !== 0 || name === primary) return;
    let slaves = [];
    try { slaves = fs.readdirSync('/sys/block/' + name + '/slaves'); } catch (e) { return; }
    if (!slaves.length) return;
    const r = buildSpaceRaidInfo(name);
    const info = new S.SpaceInfo();
    info.setType(S.SpaceType.SPACE_TYPE_SWAP);
    info.setState(S.SpaceState.SPACE_STATE_NONE);
    info.setHealthState(mdHealthy(name, r.members)
      ? S.SpaceHealthState.SPACE_HEALTH_STATE_HEALTHY
      : S.SpaceHealthState.SPACE_HEALTH_STATE_AT_RISK);
    info.setRaidMemberInfo(r.raidInfo);
    const sp = new S.Space();
    sp.setDevice(name);
    sp.setDeleted(false);
    sp.setInfo(info);
    spaces.push(sp);
  });

  // Root filesystem (plain partition on the VM disk, no raid).
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

// The Raid message — just level + hot-spare flag. Used by RaidState and
// StorageSettings. Level comes from the live primary md array.
function buildRaid() {
  const primary = baseName(volumeDevice(STORAGE_VOLUME));
  const level = primary.startsWith('md')
    ? raidLevelEnum(readFile('/sys/block/' + primary + '/md/level'))
    : raid_pb.RaidLevel.RAID_LEVEL_UNSPECIFIED;
  const raid = new raid_pb.Raid();
  raid.setRaidLevel(level);
  raid.setUseRaidHotSpare(boolValue(false));
  return raid;
}

///////////////////////////////////////////////////////////////////////////////
// Response factories
///////////////////////////////////////////////////////////////////////////////

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
function raidStateResponse() {
  const r = new api_pb.RaidStateResponse();
  r.setRaid(buildRaid());
  return r;
}
function storageSettingsResponse() {
  const r = new api_pb.StorageSettingsResponse();
  r.setRaid(buildRaid());
  r.setIsConfigured(boolValue(true));
  return r;
}
// A VM has no SD card and no flash slots — empty lists.
function flashStateResponse()  { return new api_pb.FlashStateResponse(); }
function sdCardStateResponse() { return new api_pb.SDCardStateResponse(); }

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
  const server = new grpc.Server();
  server.addService(api_grpc.StorageAPIService, {
    diskState:       streamer('DiskState',       diskStateResponse),
    flashState:      streamer('FlashState',       flashStateResponse),
    sDCardState:     streamer('SDCardState',      sdCardStateResponse),
    spaceState:      streamer('SpaceState',       spaceStateResponse),
    raidState:       streamer('RaidState',        raidStateResponse),
    storageSettings: streamer('StorageSettings',  storageSettingsResponse),
  });
  server.bindAsync(LISTEN, grpc.ServerCredentials.createInsecure(), function (err) {
    if (err) {
      log('could not bind ' + LISTEN + ': ' + err.message +
          ' — is ustated still up? (systemctl mask ustated && systemctl stop ustated)');
      process.exit(1);
    }
    log('listening on ' + LISTEN + ' — unifi.firmware.storage.v1.StorageAPI');
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
