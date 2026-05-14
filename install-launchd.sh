#!/bin/bash
###############################################################################
# install-launchd.sh
#
# Install, uninstall, or manage the launchd daemon that auto-starts the
# Protect VM at boot.
#
# WHY THIS EXISTS
#
# Without this, the VM only runs when you manually invoke start-protect-vm.sh.
# That's fine for development but unacceptable for a production NVR — if
# the Mac reboots (power loss, kernel panic, scheduled update), the VM
# stays down until a human notices and starts it.
#
# This script installs a launchd daemon (NOT a launch agent) at
# /Library/LaunchDaemons/. The daemon:
#   - Starts at boot, before any user logs in
#   - Restarts the VM if it exits for any reason
#   - Logs VM console output to /var/log/protect-vm.log
#   - Throttles restarts to once per 30 seconds to prevent runaway loops
#
# WHY launchd AND NOT cron-like alternatives
#
# launchd is the canonical way to run things at boot on macOS. It handles:
#   - Boot ordering and dependencies
#   - Process supervision (restart on exit)
#   - Logging
#   - Resource limits
#   - Graceful shutdown signaling
#
# Anything else would be fighting macOS conventions.
#
# Usage:
#   ./install-launchd.sh install <path-to-start-protect-vm.sh>
#   ./install-launchd.sh uninstall
#   ./install-launchd.sh status
#   ./install-launchd.sh start         # Start the VM now (via launchd)
#   ./install-launchd.sh stop          # Stop the VM now (via launchd)
#   ./install-launchd.sh restart       # Restart the VM
#   ./install-launchd.sh logs          # Tail the VM log
#
# Run as your normal user. The script uses sudo when needed.
###############################################################################

set -euo pipefail

# Source the config (optional — this script can still work with defaults
# if the config isn't present, but a user with a customized config wants
# their values respected).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${PROTECT_ON_MAC_CONF:-$SCRIPT_DIR/protect-on-mac.conf}"

if [ -f "$CONF_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# Defaults that match the config example. Values from the sourced config
# take precedence; these fallbacks let the script run even if the config
# is missing.
PLIST_NAME="${LAUNCHD_LABEL:-com.protect-on-mac.vm}"
PLIST_PATH="${LAUNCHD_PLIST_PATH:-/Library/LaunchDaemons/${PLIST_NAME}.plist}"
PLIST_TEMPLATE="$SCRIPT_DIR/${PLIST_NAME}.plist"
LOG_PATH="${LAUNCHD_LOG:-/var/log/protect-vm.log}"
ERROR_LOG_PATH="${LAUNCHD_ERROR_LOG:-/var/log/protect-vm.error.log}"

ACTION="${1:-}"

###############################################################################
# Helpers
###############################################################################

ensure_not_root() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "ERROR: Do not run as root. The script will use sudo when needed."
        exit 1
    fi
}

###############################################################################
# Actions
###############################################################################

install_daemon() {
    local script_path="${1:-}"

    if [ -z "$script_path" ]; then
        echo "Usage: $0 install <path-to-start-protect-vm.sh>"
        exit 1
    fi

    if [ ! -f "$script_path" ]; then
        echo "ERROR: $script_path not found"
        exit 1
    fi

    # Resolve to absolute path. launchd needs the full path.
    script_path=$(cd "$(dirname "$script_path")" && pwd)/$(basename "$script_path")

    if [ ! -x "$script_path" ]; then
        echo "Making $script_path executable..."
        chmod +x "$script_path"
    fi

    if [ ! -f "$PLIST_TEMPLATE" ]; then
        echo "ERROR: Template not found at $PLIST_TEMPLATE"
        echo "Make sure ${PLIST_NAME}.plist is in the same directory as this script."
        exit 1
    fi

    local current_user
    current_user=$(whoami)

    echo ">>> Generating launchd plist..."
    # Substitute the template placeholders. Write to a temp file first,
    # then sudo cp it into place. This avoids the user needing to write
    # directly under /Library/LaunchDaemons/.
    local tmp_plist
    tmp_plist=$(mktemp)
    sed \
        -e "s|YOUR_USERNAME|$current_user|g" \
        -e "s|SCRIPT_PATH|$script_path|g" \
        "$PLIST_TEMPLATE" > "$tmp_plist"

    echo ">>> Installing to $PLIST_PATH (sudo)..."
    sudo cp "$tmp_plist" "$PLIST_PATH"
    sudo chown root:wheel "$PLIST_PATH"
    sudo chmod 644 "$PLIST_PATH"
    rm "$tmp_plist"

    echo ">>> Creating log files..."
    sudo touch "$LOG_PATH" "$ERROR_LOG_PATH"
    sudo chown "$current_user" "$LOG_PATH" "$ERROR_LOG_PATH"

    echo ">>> Loading daemon (sudo)..."
    # bootstrap loads the plist into launchd's system domain.
    # `system` is the persistent-across-reboot domain for daemons.
    sudo launchctl bootstrap system "$PLIST_PATH"

    echo ""
    echo "Daemon installed. The VM will:"
    echo "  - Start now (running in the background)"
    echo "  - Start automatically at every boot"
    echo "  - Restart automatically if it exits"
    echo ""
    echo "Script output:        $LOG_PATH"
    echo "Script errors:        $ERROR_LOG_PATH"
    echo "VM console log:       /var/log/protect-vm.console.log"
    echo ""
    echo "Attach to live VM console:  ./attach-console.sh"
    echo "Manage daemon:              $0 {status|start|stop|restart|logs|uninstall}"
}

uninstall_daemon() {
    if [ ! -f "$PLIST_PATH" ]; then
        echo "Daemon not installed."
        return 0
    fi

    echo ">>> Unloading daemon (sudo)..."
    sudo launchctl bootout system "$PLIST_PATH" 2>/dev/null || true

    echo ">>> Removing $PLIST_PATH (sudo)..."
    sudo rm -f "$PLIST_PATH"

    echo ""
    echo "Daemon uninstalled. Logs are preserved at:"
    echo "  $LOG_PATH"
    echo "  $ERROR_LOG_PATH"
}

status_daemon() {
    if [ ! -f "$PLIST_PATH" ]; then
        echo "Status: not installed"
        return 1
    fi

    echo "Plist:  $PLIST_PATH"
    echo ""
    # `print` shows the current state of the loaded daemon. The output
    # is verbose but includes PID, last exit code, restart count, etc.
    sudo launchctl print "system/${PLIST_NAME}" 2>&1 | \
        grep -E "state|pid|last exit|active count|throttled" || \
        echo "Daemon not loaded (try: $0 install <script-path>)"
}

start_daemon() {
    echo ">>> Starting VM via launchd (sudo)..."
    sudo launchctl kickstart "system/${PLIST_NAME}"
    sleep 2
    status_daemon
}

stop_daemon() {
    echo ">>> Stopping VM via launchd (sudo)..."
    # `kill SIGTERM` sends SIGTERM to the process, which gives QEMU a
    # chance to relay it to the VM for clean shutdown. Wait a bit for
    # the VM to shut down its services and unmount /volume1 before
    # launchd's KeepAlive notices and tries to restart.
    sudo launchctl kill SIGTERM "system/${PLIST_NAME}"
}

restart_daemon() {
    echo ">>> Restarting VM via launchd (sudo)..."
    sudo launchctl kickstart -k "system/${PLIST_NAME}"
}

show_logs() {
    if [ ! -f "$LOG_PATH" ]; then
        echo "No log file yet at $LOG_PATH"
        echo "Either the daemon hasn't run, or it hasn't been installed."
        exit 1
    fi
    # -f follows new output, -n 200 shows the most recent context.
    sudo tail -n 200 -f "$LOG_PATH"
}

###############################################################################
# Execute
###############################################################################

ensure_not_root

case "$ACTION" in
    install)
        install_daemon "${2:-}"
        ;;
    uninstall)
        uninstall_daemon
        ;;
    status)
        status_daemon
        ;;
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        restart_daemon
        ;;
    logs)
        show_logs
        ;;
    *)
        echo "Usage: $0 {install <script-path>|uninstall|status|start|stop|restart|logs}"
        exit 1
        ;;
esac
