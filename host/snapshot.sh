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
# REQUIRES (host):  qemu, python3 (ships with the Xcode command-line
#                   tools, which Homebrew already depends on).
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

# Files snapshotted in the OFFLINE path. (The live path lets QEMU
# snapshot every qcow2 it has open, which is the same set.)
SNAPSHOT_FILES=("$VM_DISK")
for img in "${STORAGE_IMAGES[@]}"; do
    if [ -f "$img" ]; then
        SNAPSHOT_FILES+=("$img")
    fi
done

###############################################################################
# QMP client (live snapshots)
###############################################################################
#
# qmp_helper <op> [tag]:
#   status        print the VM run-state; exit 0 only if QEMU answered
#   savevm <tag>  snapshot-save job over every qcow2 disk
#   delvm  <tag>  snapshot-delete job over every qcow2 disk
# Exit: 0 ok, 2 usage / no qcow2 disks, 3 job reported failure,
#       4 connection problem.
#
# QEMU created the QMP socket as root, so we reach it via sudo. python3
# ships with the Xcode command-line tools that Homebrew requires.
qmp_helper() {
    sudo /usr/bin/env python3 - "$QMP_SOCKET" "$@" <<'PYEOF'
import json, socket, sys, time

if len(sys.argv) < 3:
    sys.stderr.write("usage: <socket> <status|savevm|delvm> [tag]\n")
    sys.exit(2)
sock_path, op = sys.argv[1], sys.argv[2]
tag = sys.argv[3] if len(sys.argv) > 3 else None

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(600)
    s.connect(sock_path)
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
    rx.readline()                          # QMP greeting
    cmd("qmp_capabilities")

    if op == "status":
        print(cmd("query-status").get("status", "unknown"))
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
vm_attached() {
    [ -S "$QMP_SOCKET" ] || return 1
    qmp_helper status >/dev/null 2>&1
}

###############################################################################
# Disk helpers
###############################################################################

# Reject names with anything other than letters, digits, and . _ - so
# they are safe as qemu-img tags and snapshot job tags.
validate_name() {
    case "$1" in
        ""|*[!A-Za-z0-9._-]*)
            echo "ERROR: snapshot name must be non-empty and use only" >&2
            echo "       letters, digits, and . _ -" >&2
            exit 1 ;;
    esac
}

# Is snapshot "$1" present on any of the VM's qcow2 disks? -U so it works
# while the VM is running. snapshot-save tags every disk in lockstep, but
# checking all of them is thorough either way.
snapshot_present() {
    local f
    for f in "${SNAPSHOT_FILES[@]}"; do
        if sudo qemu-img snapshot -l -U "$f" 2>/dev/null \
            | awk 'NR > 2 { print $2 }' | grep -qxF -- "$1"; then
            return 0
        fi
    done
    return 1
}

# Confirm no QEMU is attached to our images (required for restore).
check_no_qemu_attached() {
    for f in "${SNAPSHOT_FILES[@]}"; do
        if lsof "$f" 2>/dev/null | grep -q qemu; then
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

qemu_img_snapshot() {
    sudo qemu-img snapshot "$@"
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

    # Idempotent: a snapshot that already exists is left as-is. This lets
    # a named checkpoint (fresh-debian, protect-installed, ...) be
    # requested repeatedly — re-running an installer won't error out or
    # clobber the original.
    if snapshot_present "$name"; then
        echo "Snapshot '$name' already exists — left as-is."
        exit 0
    fi

    if vm_attached; then
        echo ">>> VM is running — snapshotting through QEMU."
        echo ">>> Saving '$name' across the VM's qcow2 disks..."
        if qmp_helper savevm "$name" && snapshot_present "$name"; then
            echo "Snapshot '$name' created."
        else
            echo "ERROR: live snapshot failed — see the message above." >&2
            exit 1
        fi
    else
        echo ">>> VM is not running — offline snapshot via qemu-img."
        local err=0
        for f in "${SNAPSHOT_FILES[@]}"; do
            echo "    $f"
            qemu_img_snapshot -c "$name" "$f" || err=$?
        done
        if [ "$err" -ne 0 ]; then
            echo "ERROR: one or more snapshots failed." >&2
            exit 1
        fi
        echo "Snapshot '$name' created."
    fi

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
    for f in "${SNAPSHOT_FILES[@]}"; do
        echo "=== $f ==="
        qemu_img_snapshot -l -U "$f" 2>/dev/null \
            || echo "    (no snapshots or image unreadable)"
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
    check_no_qemu_attached || exit 1

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
    for f in "${SNAPSHOT_FILES[@]}"; do
        echo "    $f"
        qemu_img_snapshot -a "$name" "$f"
    done
    echo ""
    echo "Revert complete. Start the VM to verify:"
    echo "    ./start-protect-vm.sh  (or: ./install-launchd.sh start)"
}

# Parse `qemu-img snapshot -l` into lines of "<name>|<date> <time>".
# -U so it works whether or not the VM is running.
list_snapshot_names() {
    sudo qemu-img snapshot -l -U "${SNAPSHOT_FILES[0]}" 2>/dev/null | \
        awk 'NR > 2 {
            tag = $2
            date_str = $4 " " $5
            print tag "|" date_str
        }'
}

action_rollback() {
    # Interactive rollback: list snapshots numbered, let user pick.
    # Read into an array with a loop — `mapfile` is bash 4+, and macOS
    # ships bash 3.2.
    local snapshots=() _line
    while IFS= read -r _line; do
        snapshots+=("$_line")
    done < <(list_snapshot_names)

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
        local name="${entry%%|*}"
        local date="${entry##*|}"
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

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#reversed[@]}" ]; then
        echo "Out of range."
        exit 1
    fi

    local selected_entry="${reversed[$((choice - 1))]}"
    local selected_name="${selected_entry%%|*}"
    local selected_date="${selected_entry##*|}"

    # Snapshots newer than the chosen one stay behind unless deleted.
    local selected_orig_index
    for j in "${!snapshots[@]}"; do
        if [ "${snapshots[j]%%|*}" = "$selected_name" ]; then
            selected_orig_index="$j"
            break
        fi
    done

    local newer_snapshots=()
    for ((j=selected_orig_index+1; j<${#snapshots[@]}; j++)); do
        newer_snapshots+=("${snapshots[j]%%|*}")
    done

    echo ""
    echo "Selected: $selected_name (created $selected_date)"
    echo ""

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
    for f in "${SNAPSHOT_FILES[@]}"; do
        echo "    $f"
        qemu_img_snapshot -a "$selected_name" "$f"
    done

    if [ "${do_cleanup:-0}" -eq 1 ]; then
        echo ""
        echo ">>> Deleting newer snapshots..."
        for s in "${newer_snapshots[@]}"; do
            for f in "${SNAPSHOT_FILES[@]}"; do
                echo "    $f: $s"
                qemu_img_snapshot -d "$s" "$f" 2>/dev/null \
                    || echo "      (not present)"
            done
        done
    fi

    echo ""
    echo "Rollback complete. Start the VM to verify:"
    echo "    ./start-protect-vm.sh  (or: ./install-launchd.sh start)"
}

action_delete() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: $0 delete <name>"
        exit 1
    fi
    validate_name "$name"

    if vm_attached; then
        echo ">>> Deleting snapshot '$name' through QEMU..."
        if ! qmp_helper delvm "$name"; then
            echo "ERROR: live snapshot-delete failed — see above." >&2
            exit 1
        fi
    else
        echo ">>> Deleting snapshot '$name' from all images..."
        for f in "${SNAPSHOT_FILES[@]}"; do
            echo "    $f"
            qemu_img_snapshot -d "$name" "$f" 2>/dev/null \
                || echo "    (not present in this image)"
        done
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
