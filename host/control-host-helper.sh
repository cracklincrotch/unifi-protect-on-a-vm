#!/bin/bash
###############################################################################
# control-host-helper.sh — host side of the virtio-serial control channel.
#
# WHAT THIS IS
#
# A single host↔guest control channel that the Protect VM uses to ask the
# host to do a small, fixed set of things — currently: take a qcow2
# snapshot, and run a real SMART query for the smartctl proxy.
#
# WHY virtio-serial AND NOT SSH
#
# An earlier design had the VM SSH to the host. That rides the VM's
# bridged NIC, and host<->guest traffic over a shared physical NIC is
# unreliable (the switch won't hairpin a frame back out the port it came
# in on). A virtio-serial port has no IP at all: it cannot collide with
# any LAN subnet, it is invisible to UniFi OS (it is a character device,
# not a NIC), and it is a dedicated point-to-point host<->this-guest link.
#
# THE "FORCED COMMAND" PROPERTY
#
# With SSH, a forced command is what stops a key from being a general
# shell. Here the equivalent is this script: it is NOT a shell and it
# never `eval`s anything. It is a dispatcher with a fixed verb vocabulary
# (see `dispatch`). A request for anything outside that vocabulary is not
# "denied" — it simply has no code path. Every argument is validated
# against a strict character set before use.
#
# HOW IT RUNS
#
# start-protect-vm.sh launches this with no arguments — "listen" mode —
# as the normal (non-root) user. socat opens the UNIX socket and listens;
# QEMU connects to it as a client (its chardev is server=off,reconnect).
# Doing it this way means the socket is owned by the listener's user, so
# the listener needs no privileges and start-protect-vm.sh can stop it
# with a plain kill. Each QEMU connection gets one "__serve" child that
# handles requests until the VM disconnects.
#
# PROTOCOL
#
#   request   one line:  <verb> <arg> <arg> ...\n
#   response  zero or more output lines, then a final line:
#                 __PROTECT_CTL_DONE <exit-code>\n
#
# REQUIRES (host):  socat   (brew install socat)
###############################################################################

# No `set -u`: macOS ships bash 3.2, where expanding an empty array under
# `set -u` is an error. Explicit checks are used instead.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Config resolution: $PROTECT_ON_MAC_CONF (start-protect-vm.sh exports it
# when it launches this helper), else a VM data dir / .conf as the first
# argument, else ./protect-on-mac.conf, else alongside this script.
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
# shellcheck source=/dev/null
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

# Lives under VM_DATA_DIR (not /var/run): this listener runs unprivileged
# and can't create a socket in root-owned /var/run.
CONTROL_SOCKET="${CONTROL_SOCKET:-${VM_DATA_DIR:-/tmp}/protect-vm.control.sock}"
SNAPSHOT_SH="$SCRIPT_DIR/snapshot.sh"
SMARTCTL_HELPER="$SCRIPT_DIR/smartctl-host-helper.sh"

# Pass the conf's disk map / smartctl path through to the smartctl helper
# (it reads them from the environment).
[ -n "${DISK_MAP:-}" ] && export DISK_MAP
[ -n "${SMARTCTL:-}" ] && export SMARTCTL

SENTINEL_PREFIX="__PROTECT_CTL_DONE"
MAX_TOKENS=24
MAX_ARG_LEN=64

log() { echo "[control-host-helper] $*" >&2; }

###############################################################################
# Verb handlers — each echoes its output and returns an exit code.
###############################################################################

# ping — liveness check, lets the guest confirm the channel works.
do_ping() { echo "pong"; return 0; }

# snapshot <label> — create a live qcow2 snapshot via snapshot.sh.
#
# Idempotent: if a snapshot with this label already exists it is left
# as-is and reported as success. That makes named checkpoints (e.g.
# fresh-debian) safe to request repeatedly — a re-run of an installer
# won't error or clobber the original. Timestamped labels never collide,
# so this only matters for fixed names.
do_snapshot() {
    local label="$1"
    [ -n "$label" ] || { echo "snapshot: missing label"; return 64; }
    [ "${#label}" -le "$MAX_ARG_LEN" ] || { echo "snapshot: label too long"; return 64; }
    case "$label" in
        *[!A-Za-z0-9._-]*) echo "snapshot: bad label characters"; return 64 ;;
    esac
    [ -x "$SNAPSHOT_SH" ] || { echo "snapshot: $SNAPSHOT_SH not found"; return 69; }
    # snapshot.sh needs root for the QMP socket and qemu-img. This listener
    # runs unprivileged, so invoke it with `sudo -n` — that requires a
    # NOPASSWD sudoers rule for snapshot.sh (see the README control-channel
    # section). sudo strips the environment, so PROTECT_ON_MAC_CONF would
    # be lost; pass the conf path as snapshot.sh's first argument instead.
    if sudo -n "$SNAPSHOT_SH" "$CONF_FILE" list 2>/dev/null | grep -Fqw -- "$label"; then
        echo "snapshot '$label' already exists — left as-is"
        return 0
    fi
    # </dev/null: snapshot.sh `create` is non-interactive.
    sudo -n "$SNAPSHOT_SH" "$CONF_FILE" create "$label" </dev/null 2>&1
}

# smartctl <serial> <flags...> — delegate to the smartctl proxy helper,
# which does its own strict validation and refuses state-changing flags.
do_smartctl() {
    [ -x "$SMARTCTL_HELPER" ] || { echo "smartctl: $SMARTCTL_HELPER not found"; return 69; }
    "$SMARTCTL_HELPER" "$@" 2>&1
}

dispatch() {
    local verb="$1"; shift
    case "$verb" in
        ping)     do_ping ;;
        snapshot) do_snapshot "$@" ;;
        smartctl) do_smartctl "$@" ;;
        *)        echo "unknown verb: $verb"; return 64 ;;
    esac
}

###############################################################################
# serve — one transaction loop, stdin/stdout wired to the channel by socat.
###############################################################################

serve() {
    local line verb out rc
    while IFS= read -r line; do
        # Tokenise on whitespace. The protocol's verbs (serials, flags,
        # snapshot labels) never contain spaces, so this is sufficient.
        read -r -a tok <<< "$line"
        [ "${#tok[@]}" -gt 0 ] || continue
        if [ "${#tok[@]}" -gt "$MAX_TOKENS" ]; then
            printf 'too many arguments\n%s %d\n' "$SENTINEL_PREFIX" 64
            continue
        fi
        verb="${tok[0]}"
        if out="$(dispatch "$verb" "${tok[@]:1}")"; then rc=0; else rc=$?; fi
        printf '%s\n%s %d\n' "$out" "$SENTINEL_PREFIX" "$rc"
    done
}

###############################################################################
# listen — own the socket; socat forks one __serve child per QEMU connection.
###############################################################################

listen() {
    command -v socat >/dev/null 2>&1 || { log "socat not found — 'brew install socat'"; exit 1; }
    # UNIX-LISTEN fails if the path already exists; clear a stale socket
    # left by a previous run (it's ours to remove).
    rm -f "$CONTROL_SOCKET"
    log "control channel listening on:"
    log "  $CONTROL_SOCKET"
    # fork: a fresh __serve per connection. QEMU holds one connection for
    # the VM's lifetime, so in practice that's one __serve per VM run.
    # Re-invoke via `bash` so this doesn't depend on our own execute bit.
    exec socat "UNIX-LISTEN:$CONTROL_SOCKET,fork" "EXEC:bash $0 __serve"
}

case "${1:-listen}" in
    __serve) serve ;;
    listen)  listen ;;
    *)       echo "usage: $0 [listen]" >&2; exit 64 ;;
esac
