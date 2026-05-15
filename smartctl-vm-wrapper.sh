#!/bin/bash
###############################################################################
# smartctl-vm-wrapper.sh
#
# VM side of the optional smartctl proxy. Install this INSIDE the Protect
# VM as /usr/sbin/smartctl.
#
# WHAT IT DOES
#
# Inside the VM, disks are virtio-scsi devices with no real SMART data,
# so Protect can never see genuine disk health. This wrapper intercepts
# smartctl calls, resolves the target disk to its serial number, and SSHes
# to the QEMU host — which CAN read the physical disk over USB (with the
# kasbert SAT SMART kext installed). The host's smartctl-host-helper.sh
# runs the real query and returns the output.
#
# Any failure (proxy not configured, host unreachable, unknown disk, SSH
# error) falls through to the local real smartctl. The proxy is strictly
# best-effort and cannot break the VM.
#
# INSTALL (inside the VM, as root)
#
#   apt-get install --no-install-recommends -y smartmontools openssh-client
#   systemctl disable --now smartd
#
#   # smartmontools installs the real binary at /usr/sbin/smartctl —
#   # move it aside so this wrapper can fall back to it:
#   mv /usr/sbin/smartctl /usr/sbin/smartctl.real
#
#   # Generate the key this wrapper authenticates with:
#   mkdir -p /etc/protect-smartctl-proxy && chmod 700 /etc/protect-smartctl-proxy
#   ssh-keygen -t ed25519 -N '' -C protect-smartctl-proxy \
#       -f /etc/protect-smartctl-proxy/id_ed25519
#   touch /etc/protect-smartctl-proxy/known_hosts
#   chmod 644 /etc/protect-smartctl-proxy/known_hosts
#
#   # Install this wrapper and the config:
#   install -m 0755 smartctl-vm-wrapper.sh /usr/sbin/smartctl
#   install -m 0600 smartctl-proxy.conf.example /etc/default/smartctl-proxy
#   $EDITOR /etc/default/smartctl-proxy        # set PROXY_HOST / PROXY_USER
#
# Then add /etc/protect-smartctl-proxy/id_ed25519.pub to the Mac host's
# authorized_keys with a forced command pointing at smartctl-host-helper.sh.
# See the README "smartctl proxy" section for the host-side steps.
#
# NOTE: a reinstall/upgrade of the smartmontools package will overwrite
# /usr/sbin/smartctl with the real binary again. Re-copy this wrapper if
# that happens. (smartmontools is normally apt-held on this system, so it
# only changes when you choose to update it.)
###############################################################################

PATH=/usr/sbin:/usr/bin:/sbin:/bin
REAL=/usr/sbin/smartctl.real
CONF=/etc/default/smartctl-proxy

fallback() { exec "$REAL" "$@"; }

[ -x "$REAL" ] || { echo "smartctl proxy: $REAL missing" >&2; exit 1; }
[ -r "$CONF" ] && . "$CONF"
[ -n "${PROXY_HOST:-}" ] && [ -n "${PROXY_USER:-}" ] && [ -r "${PROXY_KEY:-}" ] \
    || fallback "$@"

# Find the device argument (last token that looks like a device path).
dev=""
for a in "$@"; do
    case "$a" in /dev/*) dev="$a" ;; esac
done
[ -n "$dev" ] || fallback "$@"

# Resolve the device to its serial. unifi-core queries array-member
# partitions (e.g. /dev/sda5); SMART is a whole-disk property and the
# serial lives on the disk, so resolve a partition to its parent disk
# first. Raw-passthrough disks carry the real ATA serial on their
# virtio-scsi device; that serial is the map key.
lookup="$dev"
parent=$(lsblk -ndo PKNAME "$dev" 2>/dev/null | head -n1)
[ -n "$parent" ] && lookup="/dev/$parent"
serial=$(lsblk -ndo SERIAL "$lookup" 2>/dev/null | head -n1 | tr -d '[:space:]')
[ -n "$serial" ] || fallback "$@"

# Everything that isn't the device path is a flag to forward.
flags=()
for a in "$@"; do
    case "$a" in /dev/*) ;; *) flags+=("$a") ;; esac
done

# Ask the host. The forced command there receives "serial flags..." via
# SSH_ORIGINAL_COMMAND.
out=$(ssh -i "$PROXY_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/etc/protect-smartctl-proxy/known_hosts \
        "${PROXY_USER}@${PROXY_HOST}" -- "$serial" "${flags[@]}" 2>/dev/null)
rc=$?

if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
fi
fallback "$@"
