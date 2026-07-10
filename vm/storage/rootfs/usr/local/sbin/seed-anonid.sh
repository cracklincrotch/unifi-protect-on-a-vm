#!/bin/bash
###############################################################################
# seed-anonid.sh — faithful hardware-anonid emulation for the Protect VM.
#
# On a real UNVR the ubnthal kernel module exposes device.anonid in
# /proc/ubnthal/system.info. ubnt-systool reads it, persists it to
# /var/run/anonymous_device_id, and unifi-core reads that into settings.yaml
# (anonymous_device_id) at setup. All three agree and the value is stable
# for the life of the board (it is derived from the board hashid).
#
# A VM has no ubnthal module, so /proc/ubnthal is absent and the ubnt-tools
# `uuid` fallback is a stub that prints nothing -> `ubnt-systool anonid`
# returns empty -> settings.yaml anonymous_device_id lands null (there is no
# randomUUID fallback for that field). A null anonid is what breaks
# UP-SuperLink bridge pairing: the app sends an empty clientID.
#
# This script stands in for the kernel module WITHOUT touching any Ubiquiti
# binary. do_anonid()'s FIRST branch returns /var/run/anonymous_device_id
# verbatim when it holds a valid non-null UUID, so we simply keep that file
# populated before unifi-core reads anonid at setup-time.
#
# Value source, in precedence order (first valid wins):
#   1. the persistent store on /data (our own cache);
#   2. settings.yaml anonymous_device_id — the value unifi-core already
#      committed and that adopted devices are paired against. Anchoring to it
#      makes the emulation COHERENT with the running console automatically
#      (no hand-seeding, no drift) and self-heals a lost store;
#   3. (fresh install) a UUIDv5 DERIVED from the board serial that
#      `ubnt-tools id` reports. That serial is hardcoded in the rootfs shim
#      (a duplicated real-UNVR value), so the derived anonid is deterministic
#      and reproducible even across a /data wipe — mirroring real hardware,
#      where anonid is a deterministic function of the board. Only if no
#      board id is available do we fall back to a random UUID.
#
# The chosen value is written to the persistent store (stable across reboots
# and firmware updates — /data is the UNVR-faithful store) and re-seeded into
# tmpfs /var/run/anonymous_device_id on every boot.
#
# anonidcontroller is deliberately left alone: it stays the null UUID by
# design until a controller supplies /tmp/system.cfg
# unifi.anonymous_controller_id at adoption.
#
# Idempotent: a valid store is reused verbatim; only re-seeding the tmpfs
# copy happens every run. Paths may be overridden via the STORE / SETTINGS /
# RUNFILE environment variables (used only for testing the fresh-install
# path without touching production files).
###############################################################################
set -u

STORE="${STORE:-/data/protect-on-mac/anonid}"
RUNFILE="${RUNFILE:-/var/run/anonymous_device_id}"
SETTINGS="${SETTINGS:-/data/unifi-core/config/settings.yaml}"
UBNT_TOOLS="${UBNT_TOOLS:-/sbin/ubnt-tools}"
NULL_UUID=00000000-0000-0000-0000-000000000000
# Fixed namespace for the board-derived UUIDv5 (RFC 4122 DNS namespace).
ANONID_NS=6ba7b810-9dad-11d1-80b4-00c04fd430c8
# Same shape ubnt-systool's validate_anonid enforces: 8-4-4-4-12 hex.
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# validate_anonid: a well-formed UUID that is not the null UUID.
valid() {
    [ -n "${1:-}" ] || return 1
    [[ "$1" =~ $UUID_RE ]] || return 1
    [ "$1" != "$NULL_UUID" ] || return 1
    return 0
}

# Extract anonymous_device_id from settings.yaml (empty if null/absent). The
# hex-only capture group naturally rejects a literal `null`/`~`/empty value.
settings_anonid() {
    [ -f "$SETTINGS" ] || return 0
    sed -nE 's/^[[:space:]]*anonymous_device_id:[[:space:]]*["'\'']?([0-9a-fA-F-]+)["'\'']?[[:space:]]*$/\1/p' \
        "$SETTINGS" | head -n1
}

# RFC 4122 name-based UUIDv5 (SHA-1). Pure bash + sha1sum, no interpreter.
#   $1 = namespace UUID string, $2 = name string
uuid5() {
    local nshex="${1//-/}" bin="" i h b8
    [ ${#nshex} -eq 32 ] || return 1
    for (( i=0; i<32; i+=2 )); do bin+="\\x${nshex:i:2}"; done
    h="$( { printf '%b' "$bin"; printf '%s' "$2"; } | sha1sum | cut -c1-40 )"
    [ ${#h} -eq 40 ] || return 1
    # byte 8 (hex 16..17): force RFC variant 10xx.
    b8=$(printf '%02x' $(( (16#${h:16:2} & 0x3f) | 0x80 )))
    # group3 forces the version nibble to 5; group4 uses the variant byte.
    printf '%s-%s-5%s-%s%s-%s\n' \
        "${h:0:8}" "${h:8:4}" "${h:13:3}" "$b8" "${h:18:2}" "${h:20:12}"
}

# Deterministic anonid from the VM's stable board identity. `ubnt-tools id`
# reports a serial (and board.uuid) hardcoded in the rootfs shim, so this is
# reproducible across a /data wipe, like real hardware's board-derived anonid.
derive_from_board() {
    local key
    key="$("$UBNT_TOOLS" id 2>/dev/null \
           | sed -nE 's/^board\.serialno=([0-9a-fA-F]+).*/\1/p' | head -n1)"
    [ -n "$key" ] || key="$("$UBNT_TOOLS" id 2>/dev/null \
           | sed -nE 's/^board\.uuid=([0-9a-fA-F-]+).*/\1/p' | head -n1)"
    [ -n "$key" ] || return 1
    uuid5 "$ANONID_NS" "unifi-anonid:$key"
}

# ---------------------------------------------------------------------------
# 1. Determine the anonid: store -> settings.yaml -> board-derived -> random.
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$STORE")"

id=""
[ -f "$STORE" ] && id="$(tr -d '[:space:]' < "$STORE")"

if valid "$id"; then
    echo "seed-anonid: reusing persistent anonid $id"
else
    sid="$(settings_anonid | tr -d '[:space:]')"
    if valid "$sid"; then
        id="$sid"
        ( umask 022; printf '%s\n' "$id" > "$STORE" )
        echo "seed-anonid: adopted anonid $id from settings.yaml"
    else
        did="$(derive_from_board | tr -d '[:space:]')"
        if valid "$did"; then
            id="$did"
            ( umask 022; printf '%s\n' "$id" > "$STORE" )
            echo "seed-anonid: derived anonid $id from board id (fresh install)"
        else
            id="$(tr -d '[:space:]' < /proc/sys/kernel/random/uuid)"
            if ! valid "$id"; then
                echo "seed-anonid: failed to generate a valid UUID" >&2
                exit 1
            fi
            ( umask 022; printf '%s\n' "$id" > "$STORE" )
            echo "seed-anonid: generated random anonid $id (no board id)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2. Re-seed the tmpfs /var/run copy (wiped each boot). Write atomically and
#    fail loudly so systemd surfaces a bad seed instead of letting unifi-core
#    start gated on an empty file.
# ---------------------------------------------------------------------------
tmp="$(mktemp "${RUNFILE}.XXXXXX")" \
    || { echo "seed-anonid: mktemp failed for $RUNFILE" >&2; exit 1; }
if ! printf '%s\n' "$id" > "$tmp"; then
    echo "seed-anonid: write to $tmp failed" >&2; rm -f "$tmp"; exit 1
fi
chmod 0644 "$tmp"
if ! mv -f "$tmp" "$RUNFILE"; then
    echo "seed-anonid: mv into $RUNFILE failed" >&2; rm -f "$tmp"; exit 1
fi
echo "seed-anonid: seeded $RUNFILE = $id"
exit 0
