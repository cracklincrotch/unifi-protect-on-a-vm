#!/bin/bash
###############################################################################
# attach-console.sh
#
# Attach to the VM's serial console when it's running in background mode
# (under launchd, nohup, etc.). The same kind of access you'd get with a
# USB-to-TTL adapter on the UNVR's J1 header — useful for emergency
# recovery, watching the boot sequence, or logging in when the network is
# broken.
#
# WHEN YOU NEED THIS
#
# - VM won't come up far enough for SSH to work (initramfs problems, kernel
#   panic, network misconfiguration)
# - You want to watch boot messages in real time
# - You want to invoke a sysrq trigger or similar low-level intervention
# - The VM's network is offline but the host is fine
#
# HOW TO LEAVE
#
# Press Ctrl-O (the socat escape character configured below) to disconnect
# without affecting the VM. The VM keeps running. Multiple users can NOT
# connect to the same socket simultaneously — QEMU's unix-socket server is
# single-connection. Only one person at a time.
#
# Press Ctrl-A C inside the VM if you want to switch to the QEMU monitor
# (only available when -monitor is configured, which it isn't in background
# mode — we deliberately disable the monitor to keep the console clean).
#
# Run as your normal user. The script uses sudo to read the socket since
# QEMU creates it root-owned.
###############################################################################

set -e

# Source the config so we know where the socket is. The config also
# defines other things we don't use here.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Config resolution: $PROTECT_ON_MAC_CONF, else a VM data dir / .conf
# given as the first argument, else ./protect-on-mac.conf, else alongside
# this script. Each VM's conf lives in its own data directory.
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

if [ -f "$CONF_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# Default socket path if not specified in config. This must match the
# default in start-protect-vm.sh.
CONSOLE_SOCKET="${CONSOLE_SOCKET:-/var/run/protect-vm.console.sock}"

if [ ! -S "$CONSOLE_SOCKET" ]; then
    echo "ERROR: Console socket not found at $CONSOLE_SOCKET"
    echo ""
    echo "Possible causes:"
    echo "  - The VM isn't running"
    echo "  - The VM is running in interactive (foreground) mode — the"
    echo "    console is wherever you started it from, not on a socket"
    echo "  - The socket path was customized in start-protect-vm.sh"
    exit 1
fi

# socat is the right tool for this. nc can work but doesn't handle
# terminal modes correctly, so backspace, arrow keys, and resize don't
# behave properly. Install socat via Homebrew if you don't have it.
if ! command -v socat >/dev/null 2>&1; then
    echo "ERROR: socat is required but not installed."
    echo "Install with: brew install socat"
    exit 1
fi

echo "Attaching to VM console (Ctrl-O to disconnect)"
echo ""

# socat options breakdown:
#   - (first arg) = stdio with raw terminal mode
#   raw            = no line buffering, no signal interpretation
#   echo=0         = don't echo characters locally (the VM echoes them)
#   escape=0x0f    = Ctrl-O disconnects the socat session without killing
#                    the VM. We pick Ctrl-O because it's unlikely to be
#                    needed by any program running in the VM.
#   UNIX-CONNECT   = connect to the unix domain socket created by QEMU
sudo socat -,raw,echo=0,escape=0x0f "UNIX-CONNECT:$CONSOLE_SOCKET"

echo ""
echo "Disconnected. The VM is still running."
