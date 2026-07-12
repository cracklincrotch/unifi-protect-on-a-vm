#!/bin/bash
###############################################################################
# install-storage.sh — install the Protect VM storage subsystem.
#
# Installs every storage component as a coherent, correctly-ordered set, so a
# VM gets UNVR-faithful storage behaviour in one step. Idempotent — safe to
# re-run after a component is updated.
#
# install-protect-baremetal.sh installs this same storage layer itself, as
# its own phase (Phase 13) — so a full install does NOT need this script.
# It is kept as a standalone tool for re-applying just the storage layer by
# hand after editing one of its components.
#
# WHERE THE COMPONENTS COME FROM
#
# The files live under ../storage/rootfs/ next to this script, laid out at
# the exact paths they install to. The tree IS the manifest — this script
# walks it and installs every file at its mirrored location:
#
#   storage/rootfs/usr/bin/ustorage                   -> /usr/bin/ustorage
#   storage/rootfs/usr/local/sbin/provision-storage.sh-> /usr/local/sbin/...
#   storage/rootfs/usr/local/bin/ustated-shim.js      -> /usr/local/bin/...
#   storage/rootfs/usr/local/bin/unifi-core-storage-patch.sh
#   storage/rootfs/etc/systemd/system/*.service       -> /etc/systemd/system/
#
# BOOT ORDER (systemd):
#   provision-storage  ->  ustated-shim + unifi-core-storage-patch  ->  unifi-core
#
# storage-nuke.service is installed but NOT enabled — it runs on demand only,
# triggered by `ustorage space nuke` (the Storage UI "Erase" button).
#
# USAGE (inside the VM, as root) — only needed to re-apply the storage
# layer on its own; a full install via install-protect-baremetal.sh
# already includes it:
#   ./install-storage.sh
#
# This does not restart unifi-core. The service.js patch and the shim take
# full effect on the next unifi-core restart or a reboot.
###############################################################################
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$SRC/../storage/rootfs"
say() { echo "[install-storage] $*"; }
die() { echo "[install-storage] ERROR: $*" >&2; exit 1; }

###############################################################################
# Preflight
###############################################################################

if [ ! -d /usr/share/unifi-core/app ]; then
    say "/usr/share/unifi-core/app is missing"
    die "run install-storage.sh inside the Protect VM"
fi
command -v node24 >/dev/null 2>&1 \
    || die "node24 not on PATH — ustated-shim.service needs it"
if [ ! -d "$ROOTFS" ]; then
    say "storage payload not found at:"
    say "  $ROOTFS"
    die "run this from the vm/installers/ directory of the project tree"
fi

###############################################################################
# Back up the stock ustorage CLI before the rootfs walk overwrites it
###############################################################################

if [ -e /usr/bin/ustorage ] && ! head -3 /usr/bin/ustorage 2>/dev/null | grep -q 'ustorage-vm'; then
    if [ ! -e /usr/bin/ustorage.orig ]; then
        cp -a /usr/bin/ustorage /usr/bin/ustorage.orig
        say "backed up existing /usr/bin/ustorage -> /usr/bin/ustorage.orig"
    fi
fi

###############################################################################
# Install every file in storage/rootfs/ at its mirrored path
#
# .service files are systemd unit data (0644); everything else is an
# executable script or binary (0755). install -D creates parent dirs.
# ._* are macOS AppleDouble files — skip them; otherwise a ._foo.service
# lands in /etc/systemd/system/ and systemd logs a parse error for it.
###############################################################################

while IFS= read -r -d '' f; do
    rel="${f#"$ROOTFS"}"          # e.g. /usr/local/sbin/provision-storage.sh
    case "$rel" in
        /etc/systemd/system/*) mode=0644 ;;   # unit files (.service/.path/…)
        *)                     mode=0755 ;;
    esac
    install -D -m "$mode" "$f" "$rel"
    say "installed $rel"
done < <(find "$ROOTFS" -type f ! -name '._*' -print0)

# The provision-on-setup path unit watches /etc/ustd/storage.conf; make
# sure its directory exists so the watch attaches cleanly.
mkdir -p /etc/ustd

###############################################################################
# Wire it up
###############################################################################

# Free :11052 for the shim — ustated must not run. usd (the UI storage
# daemon) cannot run on the VM at all — mask it too so it does not fail
# noisily at every boot; provision-storage stands in for it.
systemctl mask usd ustated 2>/dev/null || true
systemctl stop usd ustated 2>/dev/null || true

systemctl daemon-reload

# Apply the service.js patch now (it also runs via its unit on every boot).
say "applying unifi-core service.js patch"
/usr/local/bin/unifi-core-storage-patch.sh || say "WARNING: patch script returned non-zero — check it"

# Enable the boot-time units. storage-nuke is intentionally NOT enabled —
# it runs on demand only (the Storage UI "Erase" button via ustorage).
# provision-on-setup.path watches /etc/ustd/storage.conf and provisions the
# array when the operator completes the storage wizard.
systemctl enable provision-storage.service \
                 ustated-shim.service \
                 unifi-core-storage-patch.service \
                 seed-anonid.service \
                 protect-backup-to-array.timer \
                 provision-on-setup.path >/dev/null
say "enabled provision-storage, ustated-shim, unifi-core-storage-patch,"
say "        seed-anonid, protect-backup-to-array.timer, provision-on-setup.path"

# The shim is safe to (re)start now; provisioning + the patch apply at boot.
systemctl restart ustated-shim.service
say "ustated-shim.service started"

###############################################################################
# Report
###############################################################################

echo
say "install complete. Current storage view:"
/usr/local/sbin/provision-storage.sh status || true
echo
say "next: restart unifi-core (or reboot) for the service.js patch + shim to"
say "      take full effect:  systemctl restart unifi-core"
