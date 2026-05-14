#!/bin/bash
###############################################################################
# snapshot.sh
#
# Create, list, restore, and delete qcow2 snapshots of the VM disks.
#
# LIVE SNAPSHOTS WITHOUT FULL SHUTDOWN
#
# Snapshots happen while the VM is RUNNING. The script briefly pauses the
# VM via QMP (QEMU Machine Protocol), runs qemu-img snapshot against each
# qcow2 file, and resumes the VM. Total VM downtime is typically a few
# seconds — far less than a full shutdown/boot cycle.
#
# The pause is critical: qemu-img snapshot rewrites the image's metadata,
# and if QEMU were still writing to the image at the same time, the
# result would be corrupt. Pausing the VM via QMP drains pending I/O and
# stops all writes cleanly, then we snapshot, then we resume.
#
# RESTORE STILL REQUIRES SHUTDOWN
#
# Reverting to a snapshot rewrites the image to match the snapshot state.
# QEMU can't continue running against a disk that's being rewritten under
# it, so restore requires a clean shutdown first. This isn't a snapshot.sh
# limitation; it's how qemu-img snapshot -a works.
#
# WHAT GETS SNAPSHOTTED
#
# qcow2 files defined in protect-on-mac.conf:
#   - VM_DISK (Debian rootfs)
#   - Each entry in STORAGE_IMAGES (typically the postgres SSD image)
#
# Raw disk passthrough (DISK_SERIALS) is NOT snapshotted. Those are real
# block devices, often 10+ TB of bulk recording storage. We accept this
# asymmetry: an update that breaks the controller can be rolled back via
# the qcow2 snapshots, and the recordings on the RAID continue
# uninterrupted.
#
# Usage:
#   ./snapshot.sh create <name>           Live snapshot (pause+snap+resume)
#   ./snapshot.sh create-auto <label>     Live snapshot named "<label>-YYYYMMDD-HHMMSS"
#   ./snapshot.sh list                    List existing snapshots
#   ./snapshot.sh restore <name>          Revert (requires VM shut down first)
#   ./snapshot.sh delete <name>           Remove a snapshot
#
# Typical workflow before a UniFi OS update:
#   1. ./snapshot.sh create-auto pre-update
#      (VM pauses ~2-5 seconds, snapshot created, VM resumes)
#   2. SSH into the VM, run the update
#   3. If broken: shut down VM, ./snapshot.sh restore <name>, start VM
###############################################################################

set -euo pipefail

# Source the config to find the disk paths and QMP socket
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${PROTECT_ON_MAC_CONF:-$SCRIPT_DIR/protect-on-mac.conf}"

if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: Config file not found at $CONF_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

# Default QMP socket (matches start-protect-vm.sh default)
QMP_SOCKET="${QMP_SOCKET:-/var/run/protect-vm.qmp.sock}"

# Build the list of files we'll snapshot
SNAPSHOT_FILES=("$VM_DISK")
for img in "${STORAGE_IMAGES[@]}"; do
    if [ -f "$img" ]; then
        SNAPSHOT_FILES+=("$img")
    fi
done

###############################################################################
# QMP helpers
###############################################################################

# Send a QMP command and capture the response. QMP is a JSON-over-socket
# protocol. We use socat to send/receive; jq is helpful for parsing.
#
# QMP requires a handshake: the server sends a greeting, the client must
# send 'qmp_capabilities' before any other command. We do this for every
# connection (socat opens a fresh connection each call, so we can't keep
# state).
qmp_command() {
    local cmd="$1"
    if ! command -v socat >/dev/null 2>&1; then
        echo "ERROR: socat is required. Install with: brew install socat" >&2
        return 1
    fi
    # Send the capabilities handshake followed by the actual command.
    # Each is a single line of JSON terminated by \n. socat -t 2 gives us
    # a 2-second timeout after EOF for QEMU's response to flush.
    {
        echo '{"execute":"qmp_capabilities"}'
        echo "$cmd"
    } | sudo socat -t 2 - "UNIX-CONNECT:$QMP_SOCKET"
}

vm_is_running() {
    [ -S "$QMP_SOCKET" ] && qmp_command '{"execute":"query-status"}' 2>/dev/null | \
        grep -q '"running"'
}

# Pause the VM. All I/O drains cleanly. Returns when the VM is fully
# stopped. Idempotent — safe to call on an already-paused VM.
qmp_pause() {
    qmp_command '{"execute":"stop"}' >/dev/null
}

# Resume a paused VM.
qmp_resume() {
    qmp_command '{"execute":"cont"}' >/dev/null
}

###############################################################################
# Disk helpers
###############################################################################

# Check that none of our images is in use by a QEMU we don't know about
# (e.g. a stale process or a different host setup using these files).
# Only used for restore, where we need exclusive access.
check_no_qemu_attached() {
    for f in "${SNAPSHOT_FILES[@]}"; do
        if lsof "$f" 2>/dev/null | grep -q qemu; then
            echo "ERROR: $f is in use by a running QEMU process." >&2
            echo "" >&2
            echo "Restore requires the VM to be shut down first." >&2
            echo "  ssh into the VM and run: systemctl poweroff" >&2
            echo "  or: ./install-launchd.sh stop  (if running as a daemon)" >&2
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

    # Decide whether to do a live snapshot (VM running) or offline (VM stopped).
    local vm_was_running=0
    if vm_is_running; then
        vm_was_running=1
        echo ">>> VM is running. Pausing briefly for a live snapshot..."
        qmp_pause
        # Brief settle time. The pause itself is synchronous so we don't
        # strictly need this, but it costs nothing and gives any
        # almost-completed I/O a moment to finalize.
        sleep 1
    else
        echo ">>> VM is not running. Taking offline snapshot."
    fi

    # Snapshot each image. Trap so we always resume the VM even if an
    # individual qemu-img call fails.
    local err=0
    trap '[ "$vm_was_running" -eq 1 ] && qmp_resume; echo "    (VM resumed after error)"' ERR

    echo ">>> Creating snapshot '$name' across ${#SNAPSHOT_FILES[@]} image(s)..."
    for f in "${SNAPSHOT_FILES[@]}"; do
        echo "    $f"
        qemu_img_snapshot -c "$name" "$f" || err=$?
    done

    trap - ERR

    if [ "$vm_was_running" -eq 1 ]; then
        echo ">>> Resuming VM..."
        qmp_resume
    fi

    if [ "$err" -ne 0 ]; then
        echo "ERROR: One or more snapshots failed." >&2
        exit 1
    fi

    echo ""
    echo "Snapshot '$name' created. Restore with:"
    echo "    $0 restore $name"
    echo "(Restore requires the VM to be shut down first.)"
}

action_create_auto() {
    local label="${1:-snapshot}"
    local name
    name="${label}-$(date +%Y%m%d-%H%M%S)"
    action_create "$name"
}

action_list() {
    for f in "${SNAPSHOT_FILES[@]}"; do
        echo "=== $f ==="
        qemu_img_snapshot -l "$f" 2>/dev/null || echo "    (no snapshots or image unreadable)"
        echo ""
    done
}

action_restore() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: $0 restore <name>"
        exit 1
    fi

    # Restore must be offline because qemu-img -a rewrites blocks while
    # QEMU may still be reading/writing them.
    check_no_qemu_attached || exit 1

    echo "About to REVERT all images to snapshot '$name'."
    echo "Any changes made since the snapshot was created will be LOST."
    echo "Images affected:"
    for f in "${SNAPSHOT_FILES[@]}"; do
        echo "  $f"
    done
    echo ""
    echo "Type 'YES' (in all capitals) to proceed, or anything else to abort:"
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

# Parse the output of `qemu-img snapshot -l` into an array of snapshot
# names with their dates. The output format from qemu-img is fixed-width
# columns: ID, TAG, VM SIZE, DATE, VM CLOCK, ICOUNT.
#
# Returns lines like: "<name>|<date> <time>"
list_snapshot_names() {
    # Use the first snapshot file as the reference. Since we always
    # create/delete in lockstep across all files, they all have the same
    # snapshot tags.
    sudo qemu-img snapshot -l "${SNAPSHOT_FILES[0]}" 2>/dev/null | \
        awk 'NR > 2 {
            # Reconstruct the tag and date. Tag is field 2, date is the
            # combination of fields N-2 and N-1 (the last two date/time
            # fields before VM CLOCK). qemu-img output:
            # ID   TAG   VM SIZE   DATE       VM CLOCK   ICOUNT
            tag = $2
            # The date is fields 4 and 5 (YYYY-MM-DD and HH:MM:SS)
            date_str = $4 " " $5
            print tag "|" date_str
        }'
}

action_rollback() {
    # Interactive rollback: list snapshots numbered, let user pick.
    local snapshots
    mapfile -t snapshots < <(list_snapshot_names)

    if [ "${#snapshots[@]}" -eq 0 ]; then
        echo "No snapshots found. Nothing to roll back to."
        echo ""
        echo "Take one before your next risky operation:"
        echo "    $0 create-auto pre-something"
        exit 1
    fi

    echo "Available snapshots (newest first):"
    echo ""
    # Show in reverse order (newest first) but keep the original index
    # so the user picks by what they see.
    printf "  %-4s %-40s %s\n" "#" "NAME" "CREATED"
    printf "  %-4s %-40s %s\n" "----" "----------------------------------------" "-------------------"

    # Build a reversed array for display
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
    echo "Enter the number of the snapshot to roll back to (or 'q' to quit):"
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

    # Figure out which snapshots are newer than the chosen one. After
    # rollback, the user may want to delete these to reclaim space.
    # Snapshots in the array are in chronological order (oldest first),
    # so anything after the selected index in the original array is newer.
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
        echo "The following ${#newer_snapshots[@]} newer snapshot(s) will REMAIN in the qcow2"
        echo "files unless you delete them. They take no extra space until you start"
        echo "writing new data, but they hold the divergent blocks from the period"
        echo "you're rolling back over."
        echo ""
        for s in "${newer_snapshots[@]}"; do
            echo "  - $s"
        done
        echo ""
        echo "Delete the newer snapshots after rolling back? (recommended unless"
        echo "you want the option to roll FORWARD to them later)"
        read -r -p "Delete newer snapshots? [y/N]: " cleanup_response
        local do_cleanup=0
        case "$cleanup_response" in
            [yY]|[yY][eE][sS]) do_cleanup=1 ;;
        esac
    fi

    # VM must be stopped for the rollback. Re-check after our prompts in
    # case anything started up in the meantime.
    check_no_qemu_attached || exit 1

    echo ""
    echo "FINAL CONFIRMATION"
    echo "About to revert all images to snapshot '$selected_name'."
    echo "Any changes since $selected_date will be LOST."
    if [ "${do_cleanup:-0}" -eq 1 ]; then
        echo "After rollback, ${#newer_snapshots[@]} newer snapshot(s) will be deleted."
    fi
    echo ""
    echo "Type 'YES' (in all capitals) to proceed, or anything else to abort:"
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
                qemu_img_snapshot -d "$s" "$f" 2>/dev/null || \
                    echo "      (not present)"
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

    # Deleting a snapshot is safe while the VM runs — qemu-img only
    # touches the snapshot's metadata, not the live image data. But we
    # still pause briefly to be safe.
    local vm_was_running=0
    if vm_is_running; then
        vm_was_running=1
        qmp_pause
        sleep 1
    fi

    trap '[ "$vm_was_running" -eq 1 ] && qmp_resume' ERR

    echo ">>> Deleting snapshot '$name' from all images..."
    for f in "${SNAPSHOT_FILES[@]}"; do
        echo "    $f"
        qemu_img_snapshot -d "$name" "$f" 2>/dev/null || \
            echo "    (snapshot not present in this image)"
    done

    trap - ERR

    if [ "$vm_was_running" -eq 1 ]; then
        qmp_resume
    fi
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
  $0 create <name>            Live snapshot (VM stays running)
  $0 create-auto <label>      Same, name "<label>-YYYYMMDD-HHMMSS"
  $0 list                     List existing snapshots
  $0 rollback                 Interactive: pick a snapshot to revert to
  $0 restore <name>           Revert to a named snapshot (requires VM shut down)
  $0 delete <name>            Remove a snapshot

Create and delete work while the VM is running. The VM is paused briefly
(typically a few seconds) during snapshot creation, then resumed.

Restore/rollback require the VM to be shut down first.

Typical workflow before a risky operation:
  1. $0 create-auto pre-update
     (VM pauses ~2-5 seconds, snapshot created, VM resumes)
  2. Do the risky thing
  3. If it broke: shut down VM, $0 rollback, pick the snapshot, start VM
EOF
        exit 1
        ;;
esac
