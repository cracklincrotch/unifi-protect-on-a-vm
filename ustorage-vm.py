#!/usr/bin/env python3
"""
ustorage-vm.py — dynamic ustorage replacement for the Protect VM.

WHAT THIS IS

On a real UNVR, `ustorage` is a thin CLI over the `usd` storage daemon.
`usd` cannot run on this VM — it's welded to the UNVR's squashfs+overlay
boot architecture and crashes resolving the root volume (see the README).
The install script's answer was a *static* fake `/usr/bin/ustorage` that
reports one hardcoded healthy disk. That works, but Protect can never see
real disk health through it.

This script is a dynamic replacement. It produces the same JSON `usd`'s
`ustorage` produces, but with live values:

  - `disk inspect`  — one entry per physical disk backing /volume1, with
                      real health derived from two independent signals.
  - `space inspect` — the primary storage volume, real capacity/usage.
  - `config show`   — RAID level read from the live array.
  - `rwfs check`    — static (migration state, not health data).

DISK FAILURE DETECTION — TWO MODES

A disk can fail in two ways, and they need different detection:

  Mode A — SMART degradation. The disk is still reachable but reports a
           failed self-assessment or failing attributes. Detected via
           `smartctl` (the proxy forwards this to the QEMU host).

  Mode B — the disk drops off the bus. The SATA link dies; the kernel
           gives up; the md array marks the member `faulty`. `smartctl`
           can't read a disk that isn't there, so SMART tells us nothing.
           Detected via the md array member state in /sys.

A real failing disk often hits both: SMART degrades, then the link
finally drops and md kicks it. This script reports a disk as failed if
*either* signal fires, so a dropped disk is never mistaken for healthy.

REQUIREMENTS

  - python3 (already present — usd, binwalk, and pip use it)
  - smartctl at /usr/sbin/smartctl. For real per-disk SMART this should
    be the smartctl proxy wrapper (install with SMARTCTL_PROXY=1). The
    md-state detection works regardless of the proxy.

INSTALL (inside the VM, as root)

  cp /usr/bin/ustorage /usr/bin/ustorage.fake     # keep the old fake
  install -m 0755 ustorage-vm.py /usr/bin/ustorage

TEST

  ustorage disk inspect   | python3 -m json.tool
  ustorage space inspect  | python3 -m json.tool

This script never raises — unifi-core depends on `ustorage` always
returning valid JSON, so every failure path degrades to an empty-but-
valid response.
"""

import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

# Path to smartctl. With SMARTCTL_PROXY this is the proxy wrapper, which
# forwards the query to the QEMU host for real disk health.
SMARTCTL = "/usr/sbin/smartctl"

# The primary storage volume — the UNVR mounts recordings storage here.
STORAGE_VOLUME = "/volume1"

# Fallback source for the storage disk if /volume1 can't be resolved.
STORAGE_DEFAULT = "/etc/default/storage_disk"

# Cache for SMART data only. SMART data is the expensive part of a
# `disk inspect` (one smartctl/proxy round-trip per disk); md array
# state is cheap sysfs reads and is always read fresh, so a disk that
# drops off the bus is reflected immediately, not after the TTL.
SMART_CACHE = "/run/ustorage-smart.cache"
SMART_CACHE_TTL = 300

# Per-disk smartctl timeout. The proxy wrapper has its own 5s connect
# timeout and fast fallback; this is just a hard ceiling.
SMARTCTL_TIMEOUT = 20

# The "threshold" field ustorage reports per disk. Its exact semantics
# are unclear — the UNVR reported 30 while disks ran well below it, and
# the old fake reported 10 while a disk ran far above it, with no alarm
# either way. Emitted as a constant to match the UNVR capture.
TEMP_THRESHOLD = 30


def _read(path):
    """Read and strip a file; '' on any error."""
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def volume_device(mountpoint):
    """Return the device backing a mountpoint, or '' if not mounted."""
    try:
        with open("/proc/self/mounts") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2 and parts[1] == mountpoint:
                    return parts[0]
    except OSError:
        pass
    return ""


def parent_disk(node):
    """Given a block device basename, return its parent whole-disk name.

    An md member may be a partition (sde5) or a whole disk (sde). A
    partition has a 'partition' attribute in sysfs; its parent is the
    directory above it in /sys."""
    if os.path.exists("/sys/class/block/%s/partition" % node):
        real = os.path.realpath("/sys/class/block/%s" % node)
        return os.path.basename(os.path.dirname(real))
    return node


def storage_array():
    """Return (device_basename, [member_basenames]) for /volume1.

    For an md array, members are the RAID component partitions/disks.
    For a plain disk, members is []."""
    name = os.path.basename(volume_device(STORAGE_VOLUME))
    members = []
    if name.startswith("md"):
        try:
            members = sorted(os.listdir("/sys/block/%s/slaves" % name))
        except OSError:
            pass
    return name, members


def md_member_states(md_name):
    """Map RAID member basename -> kernel md state string.

    State is values like 'in_sync' (active and healthy) or 'faulty'
    (the array has kicked this disk). Empty dict if not an md device."""
    states = {}
    if not md_name.startswith("md"):
        return states
    base = "/sys/block/%s/md" % md_name
    try:
        for entry in os.listdir(base):
            if entry.startswith("dev-"):
                states[entry[4:]] = _read(os.path.join(base, entry, "state"))
    except OSError:
        pass
    return states


def physical_disks():
    """List of (disk_basename, raid_member_state) backing /volume1.

    raid_member_state is the kernel md state for that disk's array
    member ('in_sync', 'faulty', ...), or '' when there is no md array."""
    name, members = storage_array()
    states = md_member_states(name)
    result = []
    seen = set()
    if members:
        for member in members:
            disk = parent_disk(member)
            if disk in seen:
                continue
            seen.add(disk)
            result.append((disk, states.get(member, "")))
    elif name:
        result.append((parent_disk(name), ""))
    if not result:
        # /volume1 unresolved — fall back to STORAGE_DISK from the config.
        for line in _read(STORAGE_DEFAULT).splitlines():
            if line.startswith("STORAGE_DISK="):
                disk = os.path.basename(line.split("=", 1)[1].strip())
                if disk:
                    result.append((parent_disk(disk), ""))
    return result


def smart(node):
    """Run smartctl --json against a disk; parsed dict, or {} on failure.

    smartctl's exit status is a bitmask (non-zero when the disk reports
    problems, and also when the disk can't be opened at all), so the
    return code is deliberately ignored — stdout is valid JSON either
    way. A disk that has dropped off the bus simply yields {} here; the
    md member state is what catches that case."""
    try:
        proc = subprocess.run(
            [SMARTCTL, "--json", "-x", "/dev/%s" % node],
            capture_output=True, text=True, timeout=SMARTCTL_TIMEOUT)
        return json.loads(proc.stdout or "{}")
    except Exception:
        return {}


def smart_for(disks):
    """Return {disk: smartdict} for the given disks, via a short-TTL
    cache so repeated disk-inspect calls don't re-run smartctl every
    time. Only SMART data is cached — md state is always read fresh."""
    cached = {}
    try:
        if time.time() - os.path.getmtime(SMART_CACHE) < SMART_CACHE_TTL:
            blob = json.loads(_read(SMART_CACHE))
            if isinstance(blob, dict):
                cached = blob
    except (OSError, ValueError):
        pass
    if disks and all(d in cached for d in disks):
        return cached
    with ThreadPoolExecutor(max_workers=8) as pool:
        fresh = dict(zip(disks, pool.map(smart, disks)))
    try:
        tmp = SMART_CACHE + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(fresh, fh)
        os.replace(tmp, SMART_CACHE)
    except OSError:
        pass
    return fresh


def _attr_raw(table, attr_id):
    """Raw value of an ATA SMART attribute by id, or 0 if absent."""
    for attr in table:
        if attr.get("id") == attr_id:
            return attr.get("raw", {}).get("value", 0) or 0
    return 0


def disk_entry(node, slot, member_state, data):
    """Build one `disk inspect` entry for a physical disk.

    member_state is the md array member state for this disk; data is the
    parsed `smartctl --json` output ({} if the disk is unreachable)."""
    table = data.get("ata_smart_attributes", {}).get("table", []) or []
    status = data.get("smart_status", {})

    # Mode B: the array kicked this disk (covers a disk that dropped off
    # the bus, where SMART can't be read at all).
    md_failed = "faulty" in member_state
    # Mode A: disk still reachable, but SMART self-assessment failed.
    smart_failed = "passed" in status and not status.get("passed", True)

    if md_failed or smart_failed:
        healthy, state = "bad", "failed"
    else:
        healthy, state = "good", "normal"

    # Count attributes currently flagged as failing (when_failed='now').
    failing = sum(1 for a in table
                  if (a.get("when_failed") or "") not in ("", "-"))
    rotation = data.get("rotation_rate", 0) or 0

    return {
        "action": "none",
        "ata": data.get("ata_version", {}).get("string", ""),
        "bad_sector": _attr_raw(table, 5),          # Reallocated_Sector_Ct
        "error_log_count": data.get("ata_smart_error_log", {})
                               .get("summary", {}).get("count", 0),
        "estimate": None,
        "firmware": data.get("firmware_version", ""),
        "healthy": healthy,
        "life_span": None,
        "model": data.get("model_name", ""),
        "node": node,
        "poweronhrs": data.get("power_on_time", {}).get("hours", 0),
        "progress": None,
        "read_error": _attr_raw(table, 1),          # Raw_Read_Error_Rate
        "reason": [],
        "rpm": rotation,
        "sata": data.get("sata_version", {}).get("string", ""),
        "serial": data.get("serial_number", ""),
        "size": data.get("user_capacity", {}).get("bytes", 0),
        "slot": slot,
        "smart_error_count": failing,
        "state": state,
        "temperature": data.get("temperature", {}).get("current", 0),
        "threshold": TEMP_THRESHOLD,
        "type": "HDD" if rotation else "SSD",
        "unc_count": _attr_raw(table, 198),         # Offline_Uncorrectable
    }


def disk_inspect():
    """`disk inspect` — real per-disk health from md state + SMART."""
    disks = physical_disks()                       # [(node, member_state)]
    smartdata = smart_for([node for node, _ in disks])
    return [disk_entry(node, slot, member_state, smartdata.get(node, {}))
            for slot, (node, member_state) in enumerate(disks, start=1)]


def raid_info(dev):
    """RAID descriptor for a space entry, or None if not an md device.

    had_most counts members actively in sync — a faulty member drops it
    below 'expected', which is how a degraded array surfaces."""
    name = os.path.basename(dev)
    if not name.startswith("md"):
        return None
    try:
        members = sorted(os.listdir("/sys/block/%s/slaves" % name))
    except OSError:
        members = []
    states = md_member_states(name)
    active = sum(1 for m in members
                 if "in_sync" in states.get(m, "in_sync"))
    try:
        expected = int(_read("/sys/block/%s/md/raid_disks" % name))
    except ValueError:
        expected = len(members)
    return {"expected": expected, "had_most": active, "members": members}


def _usage(mountpoint):
    """(total, used, resv) bytes for a mounted filesystem; zeros on error."""
    try:
        stat = os.statvfs(mountpoint)
        total = stat.f_blocks * stat.f_frsize
        free = stat.f_bfree * stat.f_frsize
        avail = stat.f_bavail * stat.f_frsize
        return total, total - free, free - avail
    except OSError:
        return 0, 0, 0


def _swap_space():
    """The swap-array space entry, or None.

    The UNVR swap partitions assemble into an md array that the VM never
    actually uses for swap. unifi-core still expects the entry, so report
    it as a zero-capacity swap space — exactly how a real UNVR reports it."""
    primary = os.path.basename(volume_device(STORAGE_VOLUME))
    try:
        names = sorted(os.listdir("/sys/block"))
    except OSError:
        return None
    for name in names:
        if not name.startswith("md") or name == primary:
            continue
        try:
            if not os.listdir("/sys/block/%s/slaves" % name):
                continue
        except OSError:
            continue
        return {
            "action": "none",
            "device": name,
            "errors_count": -1,
            "estimate": None,
            "health": "health",
            "progress": None,
            "raid": raid_info("/dev/" + name),
            "reasons": [],
            "resv_bytes": 0,
            "space_type": "swap",
            "total_bytes": 0,
            "used_bytes": 0,
        }
    return None


def _root_space():
    """The OS/root filesystem space entry. On the VM root is plain ext4 on
    its own disk, not an md array, so raid is null."""
    total, used, resv = _usage("/")
    return {
        "action": "none",
        "device": os.path.basename(volume_device("/")) or "root",
        "errors_count": 0,
        "estimate": None,
        "health": "health",
        "progress": 0.0,
        "raid": None,
        "reasons": [],
        "resv_bytes": resv,
        "space_type": "root",
        "total_bytes": total,
        "used_bytes": used,
    }


def space_inspect():
    """`space inspect` — primary, swap and root spaces with live values.

    unifi-core builds its storage model from this list; a real UNVR
    reports all three space types, so the panel won't render if any are
    missing."""
    dev = volume_device(STORAGE_VOLUME)
    total, used, resv = _usage(STORAGE_VOLUME)
    spaces = [{
        "action": "none",
        "device": os.path.basename(dev),
        "errors_count": 0,
        "estimate": None,
        "health": "health",
        "progress": None,
        "raid": raid_info(dev),
        "reasons": [],
        "resv_bytes": resv,
        "space_type": "primary",
        "total_bytes": total,
        "used_bytes": used,
    }]
    swap = _swap_space()
    if swap is not None:
        spaces.append(swap)
    spaces.append(_root_space())
    return spaces


def config_show():
    """`config show` — RAID level read from the live array."""
    name = os.path.basename(volume_device(STORAGE_VOLUME))
    raid = "raid1"
    if name.startswith("md"):
        level = _read("/sys/block/%s/md/level" % name)
        if level:
            raid = level
    return {"hotspare": False, "raid": raid}


def rwfs_check():
    """`rwfs check` — static; migration state, not health data."""
    return {"isMigrated": False,
            "migratable": {"canMigrate": False, "reason": "not-support"}}


def main():
    argv = sys.argv[1:]
    cmd = " ".join(argv[:2])
    try:
        if cmd == "disk inspect":
            print(json.dumps(disk_inspect()))
        elif cmd == "space inspect":
            print(json.dumps(space_inspect()))
        elif cmd == "config show":
            print(json.dumps(config_show()))
        elif cmd == "rwfs check":
            print(json.dumps(rwfs_check()))
        # Unknown subcommands: print nothing, exit 0 — matches the old
        # fake's behaviour so we don't surprise any caller.
    except Exception:
        # ustorage must never crash. Degrade to an empty-but-valid
        # response of the shape the caller asked for.
        if cmd in ("disk inspect", "space inspect"):
            print("[]")
        elif cmd in ("config show", "rwfs check"):
            print("{}")
    sys.exit(0)


if __name__ == "__main__":
    main()
