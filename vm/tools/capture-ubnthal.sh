#!/bin/bash
###############################################################################
# capture-ubnthal.sh — pull the real UNVR's hardware identity for comparison.
#
# The Protect VM has no ubnthal kernel module, so it fakes hardware identity
# in userspace: /sbin/ubnt-tools reports hardcoded board.* strings, and
# seed-anonid.sh supplies anonymous_device_id (see that script). Some of the
# hardcoded values were duplicated from the real UNVR; others were guessed to
# make setup pass. This helper captures the AUTHORITATIVE values from the real
# UNVR's /proc/ubnthal/system.info (exposed by the real kernel module) and
# shows them side-by-side with what the VM's shim currently reports, so you
# can (a) see the real device.anonid, and (b) find which board.* the shim
# guessed vs duplicated.
#
# Read-only on both boxes. Nothing is changed.
#
# RECOMMENDED: run from a host that can SSH to BOTH boxes (e.g. this Mac):
#     ./capture-ubnthal.sh --real 10.1.15.NN            # --vm defaults to unvr.pc
# Or run it ON the real UNVR and skip the VM diff:
#     ./capture-ubnthal.sh --vm none
#
# Options:
#   --real HOST   SSH target for the real UNVR. Omit (or 'local') to capture
#                 from the machine this script runs on.
#   --vm HOST     SSH target for the Protect VM to diff against (default:
#                 unvr.pc). Use 'none' to skip the comparison.
#   --out FILE    Save the raw capture here (default: ./ubnthal-capture-<ts>.txt).
#
# NOTE ON ADOPTING THE REAL anonid: the real device.anonid is the perfectly
# faithful value, but DO NOT drop it into a LIVE VM — it changes the anonid
# out from under any already-paired devices (e.g. UP-SuperLink) and forces a
# re-adopt. Use it only at a clean rebuild. This script only READS; it prints
# the (guarded) command but never runs it.
###############################################################################
set -u

REAL=""            # empty => local
VM="unvr.pc"
OUT=""
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"

while [ $# -gt 0 ]; do
    case "$1" in
        --real) REAL="${2:-}"; shift 2 ;;
        --vm)   VM="${2:-}";   shift 2 ;;
        --out)  OUT="${2:-}";  shift 2 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[ "$REAL" = local ] && REAL=""
[ -n "$OUT" ] || OUT="./ubnthal-capture-$(date +%Y%m%d-%H%M%S).txt"

# grab HOST COMMAND  — run COMMAND on HOST ("" = local), as root if possible.
# Commands here contain no single quotes, so simple quoting is safe.
grab() {
    local h="$1" c="$2"
    if [ -z "$h" ]; then
        if [ "$(id -u)" -eq 0 ]; then sh -c "$c"
        else sudo -n sh -c "$c" 2>/dev/null || sh -c "$c" 2>/dev/null; fi
    else
        # shellcheck disable=SC2086
        ssh $SSH_OPTS "$h" "sudo -n sh -c '$c' 2>/dev/null || sh -c '$c'" 2>/dev/null
    fi
}

# getkey TEXT KEY  — value after '=' for a "key=value" line.
getkey() {
    printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,""); print; exit}'
}

label() { [ -z "$REAL" ] && echo "REAL UNVR (local)" || echo "REAL UNVR ($REAL)"; }

echo "=============================================================="
echo " ubnthal / anonid capture — $(date)"
echo " real: $(label)   vm: ${VM:-<none>}"
echo "=============================================================="

# ---- 1. Real hardware identity --------------------------------------------
REALSYS="$(grab "$REAL" 'cat /proc/ubnthal/system.info')"
if [ -z "$REALSYS" ]; then
    echo
    echo "!! /proc/ubnthal/system.info was empty or unreadable on $(label)."
    echo "   Is this actually the real UNVR (with the ubnthal module), powered"
    echo "   on and reachable? A VM has no /proc/ubnthal."
    echo
fi
REAL_TOOLSID="$(grab "$REAL" '/sbin/ubnt-tools id')"
REAL_ANONID_SYS="$(getkey "$REALSYS" device.anonid)"
REAL_HASHID="$(getkey "$REALSYS" device.hashid)"
REAL_ANONID_TOOL="$(grab "$REAL" '/sbin/ubnt-systool anonid')"
REAL_ANONIDCTL="$(grab "$REAL" '/sbin/ubnt-systool anonidcontroller' | tail -1)"

echo
echo "----- REAL /proc/ubnthal/system.info (full) -----"
printf '%s\n' "${REALSYS:-<empty>}"

echo
echo "----- REAL anonid -----"
printf '  device.anonid (system.info) : %s\n' "${REAL_ANONID_SYS:-–}"
printf '  device.hashid (system.info) : %s\n' "${REAL_HASHID:-–}"
printf '  ubnt-systool anonid         : %s\n' "${REAL_ANONID_TOOL:-–}"
printf '  ubnt-systool anonidcontroller: %s\n' "${REAL_ANONIDCTL:-–}"
if [ -n "$REAL_ANONID_SYS" ] && [ -n "$REAL_HASHID" ]; then
    rt="${REAL_ANONID_SYS##*-}"; ht="${REAL_HASHID: -12}"
    if [ "$rt" = "$ht" ]; then
        echo "  (anonid tail == hashid tail — real anonid is board-derived, as on router.home)"
    else
        echo "  (anonid tail != hashid tail — derivation differs from the router.home sample)"
    fi
fi

# ---- 2. VM shim values + comparison ---------------------------------------
if [ "$VM" != none ] && [ -n "$VM" ]; then
    VM_TOOLSID="$(grab "$VM" '/sbin/ubnt-tools id')"
    VM_ANONID_TOOL="$(grab "$VM" '/sbin/ubnt-systool anonid')"
    VM_ANONID_SETTINGS="$(grab "$VM" 'grep anonymous_device_id /data/unifi-core/config/settings.yaml' | awk '{print $2}')"
    VM_ANONID_STORE="$(grab "$VM" 'cat /data/protect-on-mac/anonid')"

    echo
    echo "----- board.* comparison (real ubnt-tools id  vs  VM shim) -----"
    printf '  %-20s %-26s %-26s %s\n' "key" "REAL" "VM (shim)" "match"
    keys="$( { printf '%s\n' "$REAL_TOOLSID"; printf '%s\n' "$VM_TOOLSID"; } \
             | awk -F= '$1 ~ /^board\./ {print $1}' | sort -u )"
    for k in $keys; do
        rv="$(getkey "$REAL_TOOLSID" "$k")"; vv="$(getkey "$VM_TOOLSID" "$k")"
        if [ "$rv" = "$vv" ]; then m="=="; else m="DIFF"; fi
        printf '  %-20s %-26s %-26s %s\n' "$k" "${rv:-–}" "${vv:-–}" "$m"
    done

    echo
    echo "----- anonid comparison -----"
    printf '  real device.anonid          : %s\n' "${REAL_ANONID_SYS:-–}"
    printf '  VM /data/protect-on-mac/anonid: %s\n' "${VM_ANONID_STORE:-–}"
    printf '  VM settings.yaml anonid     : %s\n' "${VM_ANONID_SETTINGS:-–}"
    printf '  VM ubnt-systool anonid      : %s\n' "${VM_ANONID_TOOL:-–}"
else
    VM_TOOLSID=""; VM_ANONID_STORE=""
fi

# ---- 3. Guidance -----------------------------------------------------------
echo
echo "----- next steps -----"
if [ -n "$REAL_ANONID_SYS" ]; then
    echo "  Real anonid captured: $REAL_ANONID_SYS"
    if [ -n "${VM_ANONID_STORE:-}" ] && [ "$VM_ANONID_STORE" = "$REAL_ANONID_SYS" ]; then
        echo "  The VM already uses the real anonid — nothing to do."
    else
        echo "  To adopt it — ONLY at a clean rebuild, NEVER on the live VM"
        echo "  (it re-keys pairing and forces a device re-adopt):"
        echo "      echo $REAL_ANONID_SYS > /data/protect-on-mac/anonid"
        echo "      systemctl restart seed-anonid.service   # or reboot"
    fi
    echo "  Any board.* marked DIFF above is a shim value to reconcile in"
    echo "  /sbin/ubnt-tools (duplicate the real value for tighter fidelity)."
else
    echo "  No real device.anonid captured — re-run against the powered-on real UNVR."
fi

# ---- 4. Save raw capture ---------------------------------------------------
{
    echo "# ubnthal capture $(date)  real=$(label)  vm=${VM:-none}"
    echo "## /proc/ubnthal/system.info"
    printf '%s\n' "$REALSYS"
    echo "## real ubnt-tools id"
    printf '%s\n' "$REAL_TOOLSID"
    echo "## VM ubnt-tools id"
    printf '%s\n' "${VM_TOOLSID:-}"
} > "$OUT" 2>/dev/null && echo && echo "Raw capture saved to: $OUT"
