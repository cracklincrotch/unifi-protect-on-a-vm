#!/bin/bash
###############################################################################
# snapshot.sh
#
# Create, list, restore, and delete qcow2 snapshots of the VM disks.
#
# WHY THE VM ITSELF MUST TAKE LIVE SNAPSHOTS
#
# While QEMU runs it holds a write lock on every qcow2 it has open.
# Pausing the CPU does NOT release that lock. So an external
# `qemu-img snapshot` cannot touch the images while the VM is up; it
# fails with "Failed to get write lock". The only correct way to
# snapshot a running VM is to have QEMU do it itself.
#
# This script therefore works two ways, chosen automatically:
#
#   VM attached (QEMU running, QMP reachable):
#     create/delete go through QMP — QEMU runs a snapshot-save /
#     snapshot-delete job. The job is given an explicit device list of
#     just the qcow2 disks, so the UEFI pflash and any raw passthrough
#     disks (which cannot hold internal snapshots) are left out.
#
#   VM not attached (QEMU not running):
#     create/delete use `qemu-img snapshot` directly — no lock to fight.
#
# Listing always uses `qemu-img snapshot -l -U` (the -U force-share lets
# it read an in-use image safely).
#
# RESTORE STILL REQUIRES SHUTDOWN
#
# Reverting rewrites the image to match the snapshot. QEMU can't run
# against a disk being rewritten under it, so restore/rollback require a
# clean shutdown first. Restore is a cold revert of disk state; the saved
# RAM state is not reloaded.
#
# WHAT GETS SNAPSHOTTED
#
#   - VM attached:  every qcow2 disk QEMU has open. Raw devices (pflash,
#                   raw passthrough) cannot hold internal snapshots and
#                   are excluded — so live snapshots need qcow2 disks.
#   - VM offline:   VM_DISK plus each STORAGE_IMAGES entry (from config).
#                   Raw DISK_SERIALS passthrough is never snapshotted.
#
# Usage:
#   ./snapshot.sh create <name>        Snapshot (live if the VM is up)
#   ./snapshot.sh create-auto <label>  Same, name "<label>-YYYYMMDD-HHMMSS"
#   ./snapshot.sh list                 List existing snapshots
#   ./snapshot.sh rollback             Interactive: pick one to revert to
#   ./snapshot.sh restore <name>       Revert (VM must be shut down first)
#   ./snapshot.sh delete <name>        Remove a snapshot
#
# REQUIRES (host):  qemu, python3 (Homebrew's when installed, else the one
#                   that ships with the Xcode command-line tools).
###############################################################################

# No `set -u`: macOS ships bash 3.2, where expanding a possibly-empty
# array under `set -u` is an error. Explicit checks are used instead.
set -eo pipefail

# Source the config to find the disk paths and QMP socket
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Config resolution: $PROTECT_ON_MAC_CONF, else a VM data dir / .conf
# given as the first argument, else ./protect-on-mac.conf, else alongside
# this script. The leading-argument form matters here: snapshot.sh is also
# run via sudo from control-host-helper.sh, and sudo strips the
# environment — so the conf path is passed as snapshot.sh's first
# argument, consumed here, leaving the snapshot verb/name as $1.
CONF_FILE="${PROTECT_ON_MAC_CONF:-}"
if [ -z "$CONF_FILE" ] && [ -n "${1:-}" ]; then
    if [ -d "$1" ] && [ -f "$1/protect-on-mac.conf" ]; then
        CONF_FILE="$1/protect-on-mac.conf"; shift
    elif [ -f "$1" ] && [ "${1##*.}" = "conf" ]; then
        CONF_FILE="$1"; shift
    fi
fi
[ -z "$CONF_FILE" ] && [ -f "$PWD/protect-on-mac.conf" ] \
    && CONF_FILE="$PWD/protect-on-mac.conf"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/protect-on-mac.conf}"
export PROTECT_ON_MAC_CONF="$CONF_FILE"

if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: config file not found:" >&2
    echo "  $CONF_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

# Default QMP socket (matches start-protect-vm.sh default)
QMP_SOCKET="${QMP_SOCKET:-/var/run/protect-vm.qmp.sock}"

# Every qcow2 the VM is configured with: VM_DISK, SSD_IMAGE and the path part
# of each STORAGE_IMAGES entry. The live path lets QEMU snapshot every qcow2
# it has open, which is the same set; the offline paths and the checks below
# use this list.
SNAPSHOT_FILES=("$VM_DISK")
# /ssd1 is a qcow2 too, and since 2026-08-03 it is where the Protect DATABASE
# lives. A restore that reverts VM_DISK but not SSD_IMAGE puts 7.1 binaries in
# front of a database a newer Protect has already migrated -- a rollback that
# does not roll back. Live snapshots (QEMU enumerates every qcow2 node) already
# include it; the offline restore/delete path must too.
if [ -n "${SSD_IMAGE:-}" ]; then
    SNAPSHOT_FILES+=("$SSD_IMAGE")
fi
# STORAGE_IMAGES entries are "path|serial" (see protect-on-mac.conf.example).
for entry in "${STORAGE_IMAGES[@]}"; do
    [ -n "$entry" ] || continue
    SNAPSHOT_FILES+=("${entry%%|*}")
done
# A configured image that is missing must stop every action except list: it
# would otherwise silently drop out of the set, and a restore would revert
# the rest without it.
MISSING_FILES=()
for f in "${SNAPSHOT_FILES[@]}"; do
    [ -f "$f" ] || MISSING_FILES+=("$f")
done
require_all_present() {
    [ "${#MISSING_FILES[@]}" -eq 0 ] && return 0
    local f
    echo "ERROR: configured disk image(s) not found:" >&2
    for f in "${MISSING_FILES[@]}"; do echo "  $f" >&2; done
    echo "Nothing was changed. Put the image back, or remove it from" >&2
    echo "  $CONF_FILE" >&2
    echo "if the VM really runs without it." >&2
    exit 1
}

# Written before a restore/rollback starts reverting and removed when every
# image has been reverted. If it is still there, an earlier revert was cut
# short and the images may be at different points in time: only another
# restore/rollback (which reverts every image) may run.
RESTORE_MARKER="$(dirname "$CONF_FILE")/.snapshot-restore-in-progress"
refuse_if_restore_unfinished() {
    [ -f "$RESTORE_MARKER" ] || return 0
    echo "ERROR: a restore to snapshot '$(cat "$RESTORE_MARKER" 2>/dev/null)' did not finish," >&2
    echo "       so the images may be at different points in time. Run" >&2
    echo "       $0 restore <name> (or rollback) again first; do not start the VM." >&2
    exit 1
}

###############################################################################
# Host tools, by absolute path
###############################################################################
#
# qemu-img lives in Homebrew's bin, and this script is often started from
# places whose PATH does not include it: an ssh command, a launchd job, or
# under a sudo that resets PATH. A bare `sudo qemu-img` then failed -- and
# with its stderr
# thrown away it failed SILENTLY: list showed nothing, create reported
# failure after a good live snapshot, an offline delete reported success, and
# restore and rollback could not start. Resolve each tool once, here, from
# PATH or Homebrew's usual prefixes, and call it by full path.
# QEMU_IMG / SNAPSHOT_PYTHON (environment or config) override.
find_tool() {
    local name="$1" path="${2:-}" d
    if [ -z "$path" ]; then
        path="$(command -v "$name" 2>/dev/null || true)"
    fi
    if [ -z "$path" ]; then
        for d in /opt/homebrew/bin /usr/local/bin; do
            if [ -x "$d/$name" ]; then path="$d/$name"; break; fi
        done
    fi
    [ -n "$path" ] && [ -x "$path" ] || return 1
    echo "$path"
}
QEMU_IMG="$(find_tool qemu-img "${QEMU_IMG:-}")" || {
    echo "ERROR: qemu-img not found (brew install qemu, or set QEMU_IMG)" >&2
    exit 1
}
# The QMP helper is standard-library Python. Prefer Homebrew's python3.14 by
# name: it is the Python this host runs the project under, while
# /opt/homebrew/bin/python3 follows Homebrew upgrades (3.15 by October 2026;
# see host/qemu-patches/README.md on what a Python upgrade breaks). Then any
# Homebrew python3, then the command-line tools' /usr/bin/python3. Move the
# first entry, or set SNAPSHOT_PYTHON in the config, when the host moves on.
SNAPSHOT_PYTHON="${SNAPSHOT_PYTHON:-}"
if [ -z "$SNAPSHOT_PYTHON" ]; then
    for p in /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3 /usr/bin/python3; do
        if [ -x "$p" ]; then SNAPSHOT_PYTHON="$p"; break; fi
    done
fi
if [ -z "$SNAPSHOT_PYTHON" ] || [ ! -x "$SNAPSHOT_PYTHON" ]; then
    echo "ERROR: python3 not found (set SNAPSHOT_PYTHON)" >&2
    exit 1
fi

###############################################################################
# QMP client (live snapshots)
###############################################################################
#
# qmp_helper <op> [tag]:
#   status        print the VM run-state; exit 0 only if QEMU answered
#   savevm <tag>  snapshot-save job over every qcow2 disk
#   delvm  <tag>  snapshot-delete job over every qcow2 disk
# Exit: 0 ok, 2 usage / no qcow2 disks, 3 job reported failure,
#       4 connection problem (no QEMU listening), 5 QEMU accepted the
#       connection but did not answer within 15 s (another QMP client is
#       connected -- QEMU serves one at a time -- or QEMU is hung).
#
# QEMU created the QMP socket as root, so we reach it via sudo.
qmp_helper() {
    sudo "$SNAPSHOT_PYTHON" - "$QMP_SOCKET" "$@" <<'PYEOF'
import json, socket, sys, time

if len(sys.argv) < 3:
    sys.stderr.write("usage: <socket> <status|savevm|delvm> [tag]\n")
    sys.exit(2)
sock_path, op = sys.argv[1], sys.argv[2]
tag = sys.argv[3] if len(sys.argv) > 3 else None

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)              # greeting/handshake; raised for the job below
    s.connect(sock_path)
except socket.timeout:
    sys.stderr.write("qmp: connected but QEMU did not answer within 15 s\n")
    sys.exit(5)
except OSError as e:
    sys.stderr.write("qmp: cannot connect: %s\n" % e)
    sys.exit(4)

rx = s.makefile("r", encoding="utf-8")
_seq = [0]

def cmd(execute, **args):
    _seq[0] += 1
    rid = "c%d" % _seq[0]
    req = {"execute": execute, "id": rid}
    if args:
        req["arguments"] = args
    s.sendall((json.dumps(req) + "\n").encode())
    while True:
        line = rx.readline()
        if not line:
            raise RuntimeError("QMP connection closed")
        msg = json.loads(line)
        if msg.get("id") != rid:
            continue                       # async event — ignore
        if "error" in msg:
            raise RuntimeError(msg["error"].get("desc", str(msg["error"])))
        return msg.get("return")

try:
    try:
        rx.readline()                      # QMP greeting
        cmd("qmp_capabilities")
        st = cmd("query-status").get("status", "unknown")
    except socket.timeout:
        sys.stderr.write("qmp: connected but QEMU did not answer within 15 s "
                         "(another QMP client connected, or QEMU hung)\n")
        sys.exit(5)
    s.settimeout(600)

    if op == "status":
        print(st)
        sys.exit(0)

    if op not in ("savevm", "delvm") or not tag:
        sys.stderr.write("qmp: bad operation\n")
        sys.exit(2)

    # Every qcow2 block node — the disks we can snapshot. pflash and raw
    # passthrough devices are not qcow2 and are correctly left out.
    nodes = [n["node-name"] for n in cmd("query-named-block-nodes")
             if n.get("drv") == "qcow2"]
    if not nodes:
        sys.stderr.write("qmp: no qcow2 disks attached to snapshot\n")
        sys.exit(2)

    job = "%s_%d" % (op, int(time.time()))
    if op == "savevm":
        cmd("snapshot-save", **{"job-id": job, "tag": tag,
                                "vmstate": nodes[0], "devices": nodes})
    else:
        cmd("snapshot-delete", **{"job-id": job, "tag": tag,
                                  "devices": nodes})

    # Wait for the job to finish. If we catch it "concluded" we report
    # its error; if it auto-dismisses before we see that, the caller's
    # verification step is the backstop.
    deadline = time.time() + 580
    rc = 0
    while True:
        jobs = cmd("query-jobs")
        j = next((x for x in jobs if x.get("id") == job), None)
        if j is None:
            break                          # job finished and dismissed
        if j.get("status") == "concluded":
            err = j.get("error")
            try:
                cmd("job-dismiss", id=job)
            except RuntimeError:
                pass
            if err:
                sys.stderr.write("qmp: %s failed: %s\n" % (op, err))
                rc = 3
            break
        if time.time() > deadline:
            sys.stderr.write("qmp: %s timed out\n" % op)
            rc = 4
            break
        time.sleep(0.5)
    sys.exit(rc)

except RuntimeError as e:
    sys.stderr.write("qmp: %s\n" % e)
    sys.exit(4)
except (OSError, ValueError) as e:
    sys.stderr.write("qmp: %s\n" % e)
    sys.exit(4)
PYEOF
}

# True if QEMU is attached to the VM disks (QMP reachable). When true the
# images are locked and snapshots must go through QMP. Run state
# (running vs paused) does not matter — a paused VM still holds the lock.
#
# QEMU that accepts the connection but does not answer (busy with another QMP
# client, or hung) is neither "attached" nor "not running": it still holds
# the images, so guessing either way is unsafe. Stop instead.
vm_attached() {
    [ -S "$QMP_SOCKET" ] || return 1
    local rc=0 err
    err="$(qmp_helper status 2>&1 >/dev/null)" || rc=$?
    case "$rc" in
        0) return 0 ;;
        5) echo "ERROR: ${err#qmp: }" >&2
           echo "       Cannot tell whether the VM is running, so nothing was done." >&2
           echo "       Close other QMP clients (or check QEMU) and try again." >&2
           exit 1 ;;
        *) # Refused or no socket. QEMU's accept queue can be full of an
           # earlier timed-out probe while another client holds the
           # monitor, so make sure no process still has an image open
           # before calling the VM off.
           local f
           for f in "${SNAPSHOT_FILES[@]}"; do
               if [ -f "$f" ] && sudo /usr/sbin/lsof -t "$f" 2>/dev/null | grep -q .; then
                   echo "ERROR: QMP did not accept the connection, but a process still has" >&2
                   echo "       $f open (another QMP client is probably connected)." >&2
                   echo "       Nothing was done. Wait for it to finish and try again." >&2
                   exit 1
               fi
           done
           return 1 ;;
    esac
}

###############################################################################
# Disk helpers
###############################################################################

# Reject names with anything other than letters, digits, and . _ - so
# they are safe as qemu-img tags and snapshot job tags.
# All-digit names are refused too: qemu-img resolves a name by snapshot ID
# before tag, so "restore 1" would go to the snapshot whose ID is 1.
validate_name() {
    case "$1" in
        ""|*[!A-Za-z0-9._-]*)
            echo "ERROR: snapshot name must be non-empty and use only" >&2
            echo "       letters, digits, and . _ -" >&2
            exit 1 ;;
        *[!0-9]*) ;;
        *)
            echo "ERROR: snapshot name must not be all digits (qemu-img would" >&2
            echo "       read it as a snapshot ID)" >&2
            exit 1 ;;
    esac
}

# The snapshots in image "$1" as lines "ID<TAB>NAME<TAB>YYYY-MM-DD HH:MM:SS",
# oldest first, read from `qemu-img info --output=json`: the printed table
# splits a name that contains spaces, and its columns shift with the size
# unit. -U so it works while the VM is running. Fails (non-zero) when the
# image cannot be read, so that "unreadable" is never mistaken for "no such
# snapshot". (A name containing a tab or newline cannot be represented and
# is left out.)
snapshot_rows() {
    local out
    out="$(sudo "$QEMU_IMG" info -f qcow2 -U --output=json "$1")" || return 1
    printf '%s' "$out" | "$SNAPSHOT_PYTHON" -I -c '
import json, sys, time
for s in json.load(sys.stdin).get("snapshots", []):
    name = s.get("name", "")
    if "\t" in name or "\n" in name:
        continue
    print("%s\t%s\t%s" % (s.get("id", ""), name,
          time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(s.get("date-sec", 0)))))
'
}

# The snapshot names in image "$1", one per line (see snapshot_rows).
snapshot_tags() {
    local rows
    rows="$(snapshot_rows "$1")" || return 1
    [ -z "$rows" ] || printf '%s\n' "$rows" | cut -f2
}

# The snapshot ID(s) carrying name "$2" in image "$1", one per line (normally
# one). Restores go by ID: IDs are unique per image, while a name such as "1"
# would be looked up as ID 1 first. The name goes in through the environment
# (awk -v would process backslash escapes in it) and the comparison is forced
# to be textual (awk would otherwise call "7.1" and "7.10" equal).
snapshot_ids() {
    local rows
    rows="$(snapshot_rows "$1")" || return 1
    [ -z "$rows" ] || printf '%s\n' "$rows" | T="$2" awk -F '\t' '($2 "") == (ENVIRON["T"] "") { print $1 }'
}

# Per-image "has it / MISSING" lines for tag "$1", on stderr.
show_tag_locations() {
    local f tags
    for f in "${SNAPSHOT_FILES[@]}"; do
        if ! tags="$(snapshot_tags "$f")"; then
            echo "  UNREADABLE: $f" >&2
        elif printf '%s\n' "$tags" | grep -qxF -- "$1"; then
            echo "  has it:     $f" >&2
        else
            echo "  MISSING:    $f" >&2
        fi
    done
}

# How many of SNAPSHOT_FILES hold snapshot "$1". A snapshot is only usable
# when it is on ALL of them: the root image without /ssd1 (or the reverse) is
# a rollback that does not roll back. Call as `n="$(snapshot_count tag)" ||
# exit 1`; an unreadable image is an error, not a zero.
snapshot_count() {
    local f tags n=0
    for f in "${SNAPSHOT_FILES[@]}"; do
        if ! tags="$(snapshot_tags "$f")"; then
            echo "ERROR: cannot read the snapshot list of $f" >&2
            return 1
        fi
        if printf '%s\n' "$tags" | grep -qxF -- "$1"; then
            n=$((n + 1))
        fi
    done
    echo "$n"
}

# Confirm no QEMU is attached to our images (required for restore). QEMU
# runs as root, so lsof needs sudo to see its descriptors -- and the images
# reach it through fdsets, so ask QMP as well.
check_no_qemu_attached() {
    local f
    if vm_attached; then
        echo "ERROR: the VM is running (QMP answered on $QMP_SOCKET)." >&2
        echo "" >&2
        echo "Restore requires the VM to be shut down first." >&2
        echo "  ssh into the VM and run: systemctl poweroff" >&2
        echo "  or: ./install-launchd.sh stop  (daemon mode)" >&2
        return 1
    fi
    for f in "${SNAPSHOT_FILES[@]}"; do
        if sudo /usr/sbin/lsof "$f" 2>/dev/null | grep -q qemu; then
            echo "ERROR: image in use by a running QEMU process:" >&2
            echo "  $f" >&2
            echo "" >&2
            echo "Restore requires the VM to be shut down first." >&2
            echo "  ssh into the VM and run: systemctl poweroff" >&2
            echo "  or: ./install-launchd.sh stop  (daemon mode)" >&2
            return 1
        fi
    done
}

# Refuse a restore unless snapshot "$1" is on every image (see
# snapshot_count): reverting some images and not others leaves the OS and
# the database at different points in time.
require_on_all_images() {
    local n f ids
    n="$(snapshot_count "$1")" || exit 1
    if [ "$n" -ne "${#SNAPSHOT_FILES[@]}" ]; then
        echo "ERROR: snapshot '$1' is on $n of ${#SNAPSHOT_FILES[@]} images:" >&2
        show_tag_locations "$1"
        echo "Reverting only some images would leave the OS and the database" >&2
        echo "at different points in time, so nothing was changed." >&2
        exit 1
    fi
    # A tag held twice in one image (possible when made outside this
    # script) is ambiguous: refuse rather than pick one.
    for f in "${SNAPSHOT_FILES[@]}"; do
        ids="$(snapshot_ids "$f" "$1")" || exit 1
        case "$(printf '%s\n' "$ids" | grep -c .)" in
            1) ;;
            0) echo "ERROR: cannot find the ID of '$1' in $f. Nothing was changed." >&2
               exit 1 ;;
            *) echo "ERROR: $f holds more than one snapshot named '$1'" >&2
               echo "       (IDs: $(echo $ids)). Nothing was changed." >&2
               exit 1 ;;
        esac
    done
}

# -f qcow2: these images are always qcow2, and without it a wrong file is
# probed as raw and "has no snapshots" instead of failing.
qemu_img_snapshot() {
    sudo "$QEMU_IMG" snapshot -f qcow2 "$@"
}

###############################################################################
# Actions
###############################################################################

action_create() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: $0 create <name>"
        exit 1
    fi
    validate_name "$name"
    require_all_present
    refuse_if_restore_unfinished

    # Idempotent: a snapshot that already exists is left as-is. This lets
    # a named checkpoint (fresh-debian, protect-installed, ...) be
    # requested repeatedly — re-running an installer won't error out or
    # clobber the original. One that exists on only SOME images is not
    # usable and is not silently topped up either.
    local total="${#SNAPSHOT_FILES[@]}" n create_failed=0
    n="$(snapshot_count "$name")" || exit 1
    if [ "$n" -eq "$total" ]; then
        echo "Snapshot '$name' already exists — left as-is."
        exit 0
    elif [ "$n" -gt 0 ]; then
        echo "ERROR: snapshot '$name' already exists on $n of $total images." >&2
        echo "       Delete it first ($0 delete $name) or pick another name." >&2
        exit 1
    fi

    if vm_attached; then
        echo ">>> VM is running — snapshotting through QEMU."
        echo ">>> Saving '$name' across the VM's qcow2 disks..."
        if ! qmp_helper savevm "$name"; then
            echo "ERROR: live snapshot failed — see the message above." >&2
            create_failed=1
        fi
    else
        echo ">>> VM is not running — offline snapshot via qemu-img."
        local err=0 f
        for f in "${SNAPSHOT_FILES[@]}"; do
            echo "    $f"
            qemu_img_snapshot -c "$name" "$f" || err=$?
        done
        if [ "$err" -ne 0 ]; then
            echo "ERROR: one or more snapshots failed." >&2
            create_failed=1
        fi
    fi
    n="$(snapshot_count "$name")" || exit 1
    if [ "$create_failed" -eq 1 ] && [ "$n" -eq 0 ]; then
        exit 1
    fi
    if [ "$create_failed" -eq 1 ] || [ "$n" -ne "$total" ]; then
        if [ "$n" -eq "$total" ]; then
            echo "ERROR: the snapshot job reported a failure, yet '$name' exists on" >&2
            echo "       all $total images; treat it as suspect:" >&2
        else
            echo "ERROR: '$name' ended up on $n of $total images — not usable:" >&2
        fi
        show_tag_locations "$name"
        if [ "$n" -gt 0 ]; then
            echo "A partial snapshot was left behind (it holds disk space, and" >&2
            echo "the RAM state if the root image has it). Remove it with:" >&2
            echo "    $0 delete $name" >&2
        fi
        exit 1
    fi
    echo "Snapshot '$name' created on all $total images."

    echo ""
    echo "Restore with (VM must be shut down first):"
    echo "    $0 restore $name"
}

action_create_auto() {
    local label="${1:-snapshot}"
    action_create "${label}-$(date +%Y%m%d-%H%M%S)"
}

action_list() {
    # -U (force-share) lets qemu-img read an image that QEMU has open.
    local f out
    if [ -f "$RESTORE_MARKER" ]; then
        echo "WARNING: a restore to '$(cat "$RESTORE_MARKER" 2>/dev/null)' did not finish;"
        echo "         the images may be at different points in time."
        echo ""
    fi
    for f in "${SNAPSHOT_FILES[@]}"; do
        echo "=== $f ==="
        if [ ! -f "$f" ]; then
            echo "    (IMAGE FILE NOT FOUND -- other actions will refuse to run)"
        elif out="$(qemu_img_snapshot -l -U "$f")"; then
            if [ -n "$out" ]; then echo "$out"; else echo "    (no snapshots)"; fi
        else
            echo "    (could not read this image -- see the error above)"
        fi
        echo ""
    done
}

action_restore() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: $0 restore <name>"
        exit 1
    fi
    validate_name "$name"

    # Restore must be offline — qemu-img -a rewrites blocks that QEMU
    # would otherwise be reading and writing.
    require_all_present
    check_no_qemu_attached || exit 1
    require_on_all_images "$name"

    echo "About to REVERT all images to snapshot '$name'."
    echo "Any changes made since the snapshot was created will be LOST."
    echo "Images affected:"
    for f in "${SNAPSHOT_FILES[@]}"; do
        echo "  $f"
    done
    echo ""
    echo "Type 'YES' (all capitals) to proceed, anything else to abort:"
    read -r response
    if [ "$response" != "YES" ]; then
        echo "Aborted."
        exit 1
    fi

    echo ""
    echo ">>> Reverting to snapshot '$name'..."
    revert_all "$name"
    echo ""
    echo "Revert complete. Start the VM to verify:"
    echo "    ./start-protect-vm.sh  (or: ./install-launchd.sh start)"
}

# Revert every image to snapshot "$1" (already checked to be on all of them).
# If one fails after others succeeded the images are now at different points
# in time; say so plainly rather than carry on.
revert_all() {
    local f id done_n=0
    # Ctrl-C or a closed terminal between images would leave the images at
    # different points in time: ignore them for the few seconds this takes
    # (ignored signals are inherited by sudo and qemu-img), and leave a
    # marker in case the process is killed outright.
    trap '' INT HUP TERM
    rm -f "$RESTORE_MARKER" 2>/dev/null || true   # may be root's, from a sudo run
    printf '%s\n' "$1" > "$RESTORE_MARKER" || {
        echo "ERROR: cannot write $RESTORE_MARKER; nothing was reverted." >&2
        echo "       Remove it with sudo, or run this restore with sudo." >&2
        exit 1
    }
    for f in "${SNAPSHOT_FILES[@]}"; do
        # By this image's own ID for the tag (see snapshot_ids).
        id="$(snapshot_ids "$f" "$1")" || id=""
        echo "    $f  (snapshot ID ${id:-?})" || true
        if [ -z "$id" ]; then
            echo "ERROR: cannot find snapshot '$1' in $f." >&2
            if [ "$done_n" -gt 0 ]; then
                echo "       $done_n image(s) before it WERE reverted, so the images" >&2
                echo "       are now at different points in time. Do not start the" >&2
                echo "       VM; fix the error and run this restore again." >&2
            else
                rm -f "$RESTORE_MARKER"          # nothing was touched
            fi
            exit 1
        fi
        if ! qemu_img_snapshot -a "$id" "$f"; then
            # qemu-img writes the snapshot's L1 table before its refcount
            # passes, so a failure here can leave THIS image partly reverted.
            echo "ERROR: reverting $f failed; it may be PARTLY reverted." >&2
            [ "$done_n" -gt 0 ] && echo "       $done_n image(s) before it WERE reverted." >&2
            echo "       The images may be at different points in time. Do not start" >&2
            echo "       the VM; fix the error and run this restore again." >&2
            exit 1
        fi
        done_n=$((done_n + 1))
    done
    rm -f "$RESTORE_MARKER"
    trap - INT HUP TERM
}

# Lines of "<name><TAB><date> <time>" for the first image, oldest first.
list_snapshot_names() {
    local rows
    if ! rows="$(snapshot_rows "${SNAPSHOT_FILES[0]}")"; then
        echo "ERROR: cannot read the snapshot list of ${SNAPSHOT_FILES[0]}" >&2
        exit 1
    fi
    [ -z "$rows" ] || printf '%s\n' "$rows" | cut -f2-
}

action_rollback() {
    # Interactive rollback: list snapshots numbered, let user pick.
    # Read into an array with a loop — `mapfile` is bash 4+, and macOS
    # ships bash 3.2.
    require_all_present
    # Read the listing in this shell first: an `exit` inside a process
    # substitution only ends the subshell, which turned "cannot read the
    # image" into "No snapshots found".
    local snapshots=() _line listing
    listing="$(list_snapshot_names)" || exit 1
    while IFS= read -r _line; do
        [ -n "$_line" ] && snapshots+=("$_line")
    done <<< "$listing"

    if [ "${#snapshots[@]}" -eq 0 ]; then
        echo "No snapshots found. Nothing to roll back to."
        echo ""
        echo "Take one before your next risky operation:"
        echo "    $0 create-auto pre-something"
        exit 1
    fi

    echo "Available snapshots (newest first):"
    echo ""
    printf "  %-4s %-40s %s\n" "#" "NAME" "CREATED"
    printf "  %-4s %-40s %s\n" "----" \
        "----------------------------------------" "-------------------"

    # Build a reversed array for display (newest first).
    local reversed=()
    for ((i=${#snapshots[@]}-1; i>=0; i--)); do
        reversed+=("${snapshots[i]}")
    done

    local i=1
    for entry in "${reversed[@]}"; do
        local name="${entry%%$'\t'*}"
        local date="${entry##*$'\t'}"
        printf "  %-4s %-40s %s\n" "$i" "$name" "$date"
        i=$((i + 1))
    done

    echo ""
    echo "Enter the number to roll back to (or 'q' to quit):"
    read -r choice

    case "$choice" in
        q|Q|"") echo "Aborted."; exit 0 ;;
        *[!0-9]*) echo "Invalid choice."; exit 1 ;;
    esac
    # "08" would be octal inside $(( )); strip leading zeros.
    while [ "${#choice}" -gt 1 ] && [ "${choice#0}" != "$choice" ]; do
        choice="${choice#0}"
    done

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#reversed[@]}" ]; then
        echo "Out of range."
        exit 1
    fi

    local selected_entry="${reversed[$((choice - 1))]}"
    local selected_name="${selected_entry%%$'\t'*}"
    local selected_date="${selected_entry##*$'\t'}"

    # Snapshots newer than the chosen one stay behind unless deleted.
    local selected_orig_index
    for j in "${!snapshots[@]}"; do
        if [ "${snapshots[j]%%$'\t'*}" = "$selected_name" ]; then
            selected_orig_index="$j"
            break
        fi
    done

    # Only names that pick out exactly one snapshot in every image, and that
    # are not ALSO the name of the chosen or an older snapshot, can be
    # deleted by name safely; anything else is listed and kept.
    local newer_snapshots=() kept_shared=() n_name k f ids
    for ((j=selected_orig_index+1; j<${#snapshots[@]}; j++)); do
        n_name="${snapshots[j]%%$'\t'*}"
        local safe=1
        for ((k=0; k<=selected_orig_index; k++)); do
            [ "${snapshots[k]%%$'\t'*}" = "$n_name" ] && safe=0
        done
        for f in "${SNAPSHOT_FILES[@]}"; do
            ids="$(snapshot_ids "$f" "$n_name")" || exit 1
            [ "$(printf '%s\n' "$ids" | grep -c .)" -eq 1 ] || safe=0
        done
        if [ "$safe" -eq 1 ]; then
            newer_snapshots+=("$n_name")
        else
            kept_shared+=("$n_name")
        fi
    done

    echo ""
    echo "Selected: $selected_name (created $selected_date)"
    echo ""

    if [ "${#kept_shared[@]}" -gt 0 ]; then
        echo "Newer snapshot(s) whose name is shared with another snapshot are"
        echo "always kept (deleting by name could hit the wrong one):"
        for s in "${kept_shared[@]}"; do echo "  - $s"; done
        echo ""
    fi
    if [ "${#newer_snapshots[@]}" -gt 0 ]; then
        echo "These ${#newer_snapshots[@]} newer snapshot(s) will REMAIN in"
        echo "the qcow2 files unless you delete them. They take no extra"
        echo "space until you write new data, but they hold the divergent"
        echo "blocks from the period you're rolling back over."
        echo ""
        for s in "${newer_snapshots[@]}"; do
            echo "  - $s"
        done
        echo ""
        echo "Delete the newer snapshots after rolling back? (recommended"
        echo "unless you want to roll FORWARD to them later)"
        read -r -p "Delete newer snapshots? [y/N]: " cleanup_response
        local do_cleanup=0
        case "$cleanup_response" in
            [yY]|[yY][eE][sS]) do_cleanup=1 ;;
        esac
    fi

    # VM must be stopped for the rollback. Re-check after the prompts.
    check_no_qemu_attached || exit 1
    require_on_all_images "$selected_name"

    echo ""
    echo "FINAL CONFIRMATION"
    echo "About to revert all images to snapshot '$selected_name'."
    echo "Any changes since $selected_date will be LOST."
    if [ "${do_cleanup:-0}" -eq 1 ]; then
        echo "After rollback, ${#newer_snapshots[@]} newer snapshot(s)"
        echo "will be deleted."
    fi
    echo ""
    echo "Type 'YES' (all capitals) to proceed, anything else to abort:"
    read -r response
    if [ "$response" != "YES" ]; then
        echo "Aborted."
        exit 1
    fi

    echo ""
    echo ">>> Reverting to snapshot '$selected_name'..."
    revert_all "$selected_name"

    if [ "${do_cleanup:-0}" -eq 1 ]; then
        echo ""
        echo ">>> Deleting newer snapshots..."
        for s in "${newer_snapshots[@]}"; do
            delete_offline "$s" once || true
        done
    fi

    echo ""
    echo "Rollback complete. Start the VM to verify:"
    echo "    ./start-protect-vm.sh  (or: ./install-launchd.sh start)"
}

# Delete snapshot "$1" from every image that holds it (VM not running).
# Images without it are skipped and said so; a failed delete is shown and
# makes this return non-zero.
delete_offline() {
    local f tags err=0 tries max=10
    [ "${2:-}" = once ] && max=1
    for f in "${SNAPSHOT_FILES[@]}"; do
        if ! tags="$(snapshot_tags "$f")"; then
            echo "    $f: could not read its snapshot list" >&2
            err=1; continue
        fi
        if printf '%s\n' "$tags" | grep -qxF -- "$1"; then
            echo "    $f: $1"
            # A tag can be held more than once (made outside this script);
            # each -d removes one, so repeat until it is gone.
            tries=0
            while printf '%s\n' "$tags" | grep -qxF -- "$1" && [ "$tries" -lt "$max" ]; do
                qemu_img_snapshot -d "$1" "$f" || { err=1; break; }
                tries=$((tries + 1))
                tags="$(snapshot_tags "$f")" || { err=1; break; }
            done
        else
            echo "    $f: $1 (not in this image)"
        fi
    done
    return "$err"
}

action_delete() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: $0 delete <name>"
        exit 1
    fi
    # Charset only: an all-digit tag made elsewhere must still be deletable,
    # and delete matches by tag (no ID lookup).
    case "$name" in
        ""|*[!A-Za-z0-9._-]*)
            echo "ERROR: snapshot names use only letters, digits, and . _ -" >&2
            exit 1 ;;
    esac
    require_all_present
    refuse_if_restore_unfinished

    local n
    n="$(snapshot_count "$name")" || exit 1
    if [ "$n" -eq 0 ]; then
        echo "ERROR: no snapshot named '$name' on any image ($0 list)." >&2
        exit 1
    fi

    if vm_attached; then
        echo ">>> Deleting snapshot '$name' through QEMU..."
        if ! qmp_helper delvm "$name"; then
            echo "ERROR: live snapshot-delete failed — see above." >&2
            exit 1
        fi
    else
        echo ">>> Deleting snapshot '$name' from all images..."
        delete_offline "$name" || true
    fi
    n="$(snapshot_count "$name")" || exit 1
    if [ "$n" -ne 0 ]; then
        echo "ERROR: '$name' is still on $n image(s):" >&2
        show_tag_locations "$name"
        exit 1
    fi
    echo "Snapshot '$name' deleted."
}

###############################################################################
# Execute
###############################################################################

ACTION="${1:-}"
shift || true

case "$ACTION" in
    create)      action_create "$@" ;;
    create-auto) action_create_auto "$@" ;;
    list|ls)     action_list ;;
    restore)     action_restore "$@" ;;
    rollback)    action_rollback ;;
    delete|rm)   action_delete "$@" ;;
    *)
        cat <<EOF
Usage:
  $0 create <name>        Snapshot (live if the VM is running)
  $0 create-auto <label>  Same, name "<label>-YYYYMMDD-HHMMSS"
  $0 list                 List existing snapshots
  $0 rollback             Interactive: pick a snapshot to revert to
  $0 restore <name>       Revert to a named snapshot
                          (requires the VM shut down first)
  $0 delete <name>        Remove a snapshot

Create and delete work while the VM is running — QEMU takes the
snapshot itself, pausing the VM only momentarily.

Restore and rollback require the VM to be shut down first.

Typical workflow before a risky operation:
  1. $0 create-auto pre-update
  2. Do the risky thing
  3. If it broke: shut down the VM, then $0 rollback, then start it
EOF
        exit 1
        ;;
esac
