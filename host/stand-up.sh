#!/bin/bash
###############################################################################
# stand-up.sh — create a fresh Protect VM from scratch on macOS.
#
# WHAT THIS DOES
#
# start-protect-vm.sh runs an already-installed VM. This script is the step
# before that: it builds the artifacts start-protect-vm.sh needs and walks
# you through the one-time Debian install.
#
#   1. Download the Debian netinst ISO (cached + SHA256-verified).
#   2. Create the OS disk (VM_DISK), the UEFI vars file (EFI_VARS), and a
#      blank qcow2 for every STORAGE_IMAGES entry in protect-on-mac.conf.
#   3. Boot QEMU with the ISO attached so you do the Debian install
#      interactively over the serial console.
#   4. Hand off to start-protect-vm.sh.
#
# The installer boot is deliberately minimal: only the OS disk and the ISO
# are attached — no raw-disk passthrough, so it needs no sudo — and the
# blank data disks are left detached so the Debian partitioner can't touch
# them and they stay pristine for first boot. Networking is user-mode NAT,
# which is all the netinst needs and means NIC_MAC isn't required yet.
#
# HOST PREREQUISITES
#
# This script sets these up itself: it offers to install Homebrew if it's
# missing, installs qemu and socat through it, offers to add a passwordless
# sudo rule for snapshot.sh (so the VM can trigger host-side snapshots over
# the control channel), and optionally sets up the smartctl proxy host side
# (smartmontools + the SAT SMART kext installer). curl, shasum, and unzip
# ship with macOS.
#
# USAGE (on the macOS host)
#
#   cp protect-on-mac.conf.example protect-on-mac.conf   # if not done yet
#   $EDITOR protect-on-mac.conf       # set VM_DATA_DIR, STORAGE_IMAGES
#   ./stand-up.sh
#
# CONFIG KNOBS (optional, in protect-on-mac.conf or the environment)
#   VM_DISK_SIZE     OS disk size           (default 32G)
#   DEBIAN_VERSION   Debian point release   (default 11.11.0 — matches the
#                                            existing Test-UNVR)
#   DEBIAN_ARCH      arm64 | amd64          (default arm64)
###############################################################################
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Config resolution: $PROTECT_ON_MAC_CONF, else a VM data dir / .conf as
# the first argument, else ./protect-on-mac.conf, else alongside this
# script. On a fresh run none of these exist yet — stand-up.sh creates the
# conf from the example and, once VM_DATA_DIR is chosen, moves it into the
# VM's data directory (where every VM keeps its own config).
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

say() { echo "[stand-up] $*"; }
die() { echo "[stand-up] ERROR: $*" >&2; exit 1; }

# True if a directory already holds a VM — any disk image or the EFI
# varstore. Used to stop a new VM from being pointed at an existing one's
# directory. A literal unmatched glob fails `[ -e ]`, so no nullglob needed.
dir_has_vm() {
    local d="$1" f
    [ -d "$d" ] || return 1
    for f in "$d"/*.qcow2 "$d"/efi_vars.fd; do
        [ -e "$f" ] && return 0
    done
    return 1
}

###############################################################################
# Config
###############################################################################

# First run: create the config from the example and keep going. The
# example ships with working defaults; storage and network are configured
# by the interactive step further down, and VM_DATA_DIR is prompted just
# below — so there is no edit-and-re-run step.
if [ ! -f "$CONF_FILE" ]; then
    [ -f "$SCRIPT_DIR/protect-on-mac.conf.example" ] \
        || die "no $CONF_FILE and no protect-on-mac.conf.example to seed it from"
    cp "$SCRIPT_DIR/protect-on-mac.conf.example" "$CONF_FILE"
    say "created $CONF_FILE from the example."
fi
# shellcheck source=/dev/null
source "$CONF_FILE"

# VM_DATA_DIR — where THIS VM's files live (OS disk, data disks, EFI vars,
# installer ISO). The example default ($HOME/unifi-protect/vm-data) is the
# same for every VM on a host, so a second stand-up.sh run would point at
# the first VM's directory. While VM_DATA_DIR still holds that shared
# default, prompt for a per-VM directory — suggesting one beside wherever
# stand-up.sh was invoked. Once a non-default value is set this is skipped.
if [ "${VM_DATA_DIR:-}" = "$HOME/unifi-protect/vm-data" ]; then
    _base="$PWD/vm-data"
    _default_dir="$_base"
    _n=1
    echo
    say "Each VM needs its own directory for its files (OS disk, data"
    say "disks, EFI vars, installer ISO). The config still has the shared"
    say "default. Choose a directory for THIS VM:"
    while :; do
        read -r -p "  VM data directory [$_default_dir]: " _vmdir
        _vmdir="${_vmdir:-$_default_dir}"
        _vmdir="${_vmdir/#\~/$HOME}"        # expand a leading ~
        case "$_vmdir" in /*) ;; *) _vmdir="$PWD/$_vmdir" ;; esac
        _vmdir="${_vmdir%/}"
        # Refuse to silently point a NEW VM at a directory that already
        # holds one — that risks overwriting or conflating it.
        if dir_has_vm "$_vmdir"; then
            echo
            say "WARNING: $_vmdir already contains a VM"
            say "(disk images / EFI vars). Reusing it risks overwriting or"
            say "conflating that VM with this one."
            read -r -p "  [c]hoose another directory, or [u]se it anyway? [c]: " _ans
            case "$_ans" in
                u|U) break ;;
                *)   _n=$((_n + 1)); _default_dir="${_base}-${_n}"
                     echo; continue ;;
            esac
        fi
        break
    done
    NEW_VMDIR="$_vmdir" perl -pi -e \
        's/^VM_DATA_DIR=.*$/VM_DATA_DIR="$ENV{NEW_VMDIR}"/' "$CONF_FILE" \
        || die "failed to set VM_DATA_DIR in $CONF_FILE"
    say "VM files will live under: $_vmdir"
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

: "${VM_DATA_DIR:?VM_DATA_DIR not set in $CONF_FILE}"

# Each VM owns its config: protect-on-mac.conf lives in the VM's data
# directory, beside its disks — so the script tree can be wiped/updated
# without touching a VM, and two VMs never share a conf. Move it there if
# it is not already. The other host scripts find it via that directory
# (an argument, $PWD, or the path baked into the launchd plist).
mkdir -p "$VM_DATA_DIR" || die "could not create $VM_DATA_DIR"
_vm_conf="$VM_DATA_DIR/protect-on-mac.conf"
if [ "$CONF_FILE" != "$_vm_conf" ]; then
    if [ -e "$_vm_conf" ]; then
        # The chosen VM directory already has a config. The operator
        # reached here by reusing that directory, so adopt the existing
        # config rather than overwriting it; discard the stub just
        # created from the example, and re-source so the rest of
        # stand-up.sh sees the adopted values.
        say "adopting the config already in $VM_DATA_DIR"
        rm -f "$CONF_FILE"
        CONF_FILE="$_vm_conf"
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    else
        mv "$CONF_FILE" "$_vm_conf" \
            || die "could not move the config into $VM_DATA_DIR"
        CONF_FILE="$_vm_conf"
        say "config now lives with the VM: $CONF_FILE"
    fi
fi
export PROTECT_ON_MAC_CONF="$CONF_FILE"

: "${VM_DISK:?VM_DISK not set in $CONF_FILE}"
: "${EFI_VARS:?EFI_VARS not set in $CONF_FILE}"
: "${EFI_CODE:?EFI_CODE not set in $CONF_FILE}"
VM_CPUS="${VM_CPUS:-4}"
VM_RAM="${VM_RAM:-4096}"
VM_DISK_SIZE="${VM_DISK_SIZE:-32G}"
DEBIAN_VERSION="${DEBIAN_VERSION:-11.11.0}"
DEBIAN_ARCH="${DEBIAN_ARCH:-arm64}"
STORAGE_IMAGES=("${STORAGE_IMAGES[@]:-}")

# ISO cache lives outside VM_DATA_DIR so wiping a VM's data dir to rebuild
# it does not nuke the large Debian ISO download. The conf sets ISO_DIR;
# fall back to a sibling 'isos' dir for an older conf that predates it.
ISO_DIR="${ISO_DIR:-${VM_DATA_DIR%/*}/isos}"
ISO_NAME="debian-${DEBIAN_VERSION}-${DEBIAN_ARCH}-netinst.iso"
ISO_PATH="$ISO_DIR/$ISO_NAME"
ISO_BASE="https://cdimage.debian.org/cdimage/archive/${DEBIAN_VERSION}/${DEBIAN_ARCH}/iso-cd"

###############################################################################
# Intro
###############################################################################

cat <<EOF

===============================================================================
  stand-up.sh — create a fresh UniFi Protect VM on this Mac
===============================================================================

This is a one-time, interactive setup. It will, in order:

  1. Check host prerequisites — Homebrew, qemu, socat — and offer to
     install anything missing.
  2. Offer to add sudoers rules so the VM starts without a password
     (also required for launchd) and can trigger host-side snapshots.
     That step asks for your macOS password, and explains exactly why
     before it does.
  3. Optionally set up the smartctl proxy host side (smartmontools + the
     SAT SMART kext installer).
  4. Walk you through storage + network configuration — which physical
     disks to pass through (with RAID detection), whether to create
     virtual storage images, and which adapter to bridge — and write
     those choices into protect-on-mac.conf for you.
  5. Download and SHA256-verify the Debian ${DEBIAN_VERSION} ${DEBIAN_ARCH}
     netinst ISO (cached — only downloaded once).
  6. Create the VM's OS disk, UEFI variable store, and blank data disks
     under: $VM_DATA_DIR
  7. Boot the Debian installer on THIS terminal (serial console). The
     install is fully automated by preseed — no input needed; expect
     roughly 10-15 minutes.

You will be asked once, up front, to set the VM's root password.

It stops and asks before anything significant. Nothing outside the VM
data directory shown in step 5 is modified — except the one optional
sudoers file in step 2. When the Debian install finishes, you hand off
to start-protect-vm.sh.

EOF
read -r -p "Press Enter to begin, or Ctrl-C to abort: " _

###############################################################################
# Preflight — host prerequisites
###############################################################################

# Make sure Homebrew is available. brew may be installed but not yet on
# PATH (common right after installing it), so look in the standard spots.
ensure_homebrew() {
    command -v brew >/dev/null 2>&1 && return 0
    local b
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$b" ]; then eval "$("$b" shellenv)"; return 0; fi
    done
    say "Homebrew is not installed — it provides qemu and socat."
    read -r -p "  Install Homebrew now? [y/N]: " ans
    case "$ans" in
        y|Y) ;;
        *)   die "Homebrew required — install it from https://brew.sh and re-run" ;;
    esac
    /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || die "Homebrew installation failed"
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$b" ] && eval "$("$b" shellenv)"
    done
    command -v brew >/dev/null 2>&1 || die "brew still not on PATH after install"
}

# Install a Homebrew formula if the named command isn't already available.
ensure_brew_cmd() {
    local cmd="$1" formula="$2"
    command -v "$cmd" >/dev/null 2>&1 && return 0
    say "installing $formula via Homebrew..."
    brew install "$formula" || die "brew install $formula failed"
}

# Add the passwordless sudo rules the project needs, in one file
# (/etc/sudoers.d/protect-on-mac). Two things run as root:
#   - qemu-system-aarch64 : start-protect-vm.sh starts the VM with sudo
#                           (raw disk access needs root). Without this,
#                           every VM start prompts for a password — and
#                           launchd cannot start the VM unattended at all.
#   - snapshot.sh         : the VM triggers host-side snapshots over the
#                           control channel; the listener runs it via sudo -n.
# (The smartctl proxy needs no rule — smartctl reads SMART through IOKit
# on macOS, which works unprivileged.)
# A sudoers.d file is normally unreadable to non-root, so when one already
# exists and we cannot confirm its contents we offer to refresh it rather
# than silently trusting it (it may predate the qemu rule).
ensure_sudoers() {
    local rule_file=/etc/sudoers.d/protect-on-mac
    local snap="$SCRIPT_DIR/snapshot.sh"
    local user qemu qemu_rule snap_rule ans tmp existing desired
    user="$(id -un)"
    qemu="$(command -v qemu-system-aarch64 \
            || echo /opt/homebrew/bin/qemu-system-aarch64)"

    [ -f "$snap" ] || { say "snapshot.sh not next to stand-up.sh — skipping sudoers"; return 0; }

    qemu_rule="$user ALL=(root) NOPASSWD: $qemu"
    snap_rule="$user ALL=(root) NOPASSWD: $snap"

    # Explain BEFORE touching sudo — the password prompt below should never
    # appear without the user knowing exactly what it is for.
    cat <<EOF

[stand-up] OPTIONAL — passwordless sudo for the VM
--------------------------------------------------
The project runs two things as root: start-protect-vm.sh launches QEMU
(raw disk access), and the VM triggers host-side snapshots over the
control channel. Without a sudoers rule each needs your password every
time — and launchd cannot start the VM unattended at all.

This updates one file, $rule_file. It keeps a
single QEMU rule plus one snapshot.sh rule per VM — merging with rules
already there for your other VMs, and pruning any whose script tree no
longer exists. This run contributes:

  $qemu_rule
  $snap_rule

If you agree, macOS asks for YOUR login password next — sudo authorising
the read and rewrite of that one file. Decline and the VM simply prompts
for a password on each start (snapshots/SMART still degrade gracefully).

EOF
    read -r -p "  Update the sudoers rules now? [Y/n]: " ans
    case "$ans" in
        n|N) say "skipped — VM start will prompt for a password"; return 0 ;;
    esac
    say "you will now be prompted for your macOS password (sudo)..."

    # Read any existing rules (root-only file; missing -> empty).
    existing="$(sudo cat "$rule_file" 2>/dev/null || true)"

    # Rebuild: one QEMU rule, then a snapshot.sh rule per VM tree — this
    # run's plus every existing one whose snapshot.sh still exists (trees
    # that were deleted are dropped). Deduplicated and sorted.
    local snap_rules line p
    snap_rules="$snap_rule"
    while IFS= read -r line; do
        case "$line" in
            *"ALL=(root) NOPASSWD: "*/snapshot.sh)
                p="${line##*NOPASSWD: }"
                [ -f "$p" ] && snap_rules="$snap_rules"$'\n'"$line"
                ;;
        esac
    done <<EOF
$existing
EOF
    desired="$qemu_rule"$'\n'"$(printf '%s\n' "$snap_rules" | sort -u)"

    if [ "$existing" = "$desired" ]; then
        say "sudoers rules already current ($rule_file)."
        return 0
    fi

    tmp="$(mktemp)"
    printf '%s\n' "$desired" > "$tmp"
    if sudo visudo -cf "$tmp" >/dev/null 2>&1; then
        if sudo install -m 0440 -o root -g wheel "$tmp" "$rule_file"; then
            say "updated sudoers rules: $rule_file"
            say "  ($(printf '%s\n' "$desired" | grep -c 'snapshot.sh') VM(s) authorised for host snapshots)"
        else
            say "WARNING: could not install $rule_file"
        fi
    else
        say "WARNING: the generated sudoers rules failed validation — not installed"
    fi
    rm -f "$tmp"
}

# SAT SMART kext installer (binaryfruit, bundles the kasbert driver).
SATSMART_URL="https://binaryfruit.com/download/mac/satsmartdriver/SATSMARTDriver-0.10.3.macOS11_and_AppleSilicon.zip"

# Set up the host side of the smartctl proxy — smartmontools (the real
# smartctl the host helper runs) and the SAT SMART kext installer (so
# macOS can read SMART over USB). Strongly recommended: without it
# Protect can't manage disk storage (arrays, SMART). Still a prompt,
# since the kext itself can't be installed unattended (Apple Silicon
# needs Reduced Security) — this fetches the installer and prints the
# manual steps.
maybe_setup_smartctl_proxy() {
    cat <<'EOF'

[stand-up] smartctl proxy — HIGHLY RECOMMENDED

The smartctl proxy lets Protect see real disk health for the VM's
USB-attached disks. Without it, Protect cannot properly manage disk
storage — including, but not limited to, creating storage arrays and
S.M.A.R.T. monitoring. It is not strictly required, but skipping it
means you will have to configure the disks manually.

Its host side needs smartmontools and a SAT SMART kext. This fetches
the SIGNED SATSMARTDriver kext from binaryfruit.com — the vendor of
DriveDx, a well-known Mac disk-health app — so it comes from a
recognized source, not a random host.

You can skip this and re-run stand-up.sh later to set it up.

EOF
    read -r -p "  Set up the smartctl proxy host side now? [Y/n]: " ans
    case "$ans" in
        n|N) return 0 ;;
        *)   ;;
    esac

    ensure_brew_cmd smartctl smartmontools

    local outdir="$VM_DATA_DIR/SATSMARTDriver" dl
    if [ -d "$outdir" ]; then
        say "SAT SMART kext installer already present:"
        say "  $outdir"
    else
        dl="$VM_DATA_DIR/SATSMARTDriver.zip"
        say "downloading the signed SAT SMART kext installer..."
        say "  source: https://binaryfruit.com  (makers of DriveDx)"
        if curl -fSL --connect-timeout 15 -o "$dl" "$SATSMART_URL"; then
            mkdir -p "$outdir"
            unzip -o -q "$dl" -d "$outdir" || say "WARNING: unzip failed: $dl"
            rm -f "$dl"
            say "SAT SMART kext installer extracted to:"
            say "  $outdir"
        else
            say "WARNING: kext installer download failed. Fetch it"
            say "manually (linked from https://binaryfruit.com):"
            say "  $SATSMART_URL"
            return 0
        fi
    fi

    cat <<EOF

[stand-up] To finish the smartctl proxy host setup:
  1. Run the installer extracted under:
       $outdir
  2. Loading a third-party kext on Apple Silicon needs Reduced Security —
     reboot into recoveryOS, open Startup Security Utility, allow reduced
     security, then approve the kext under System Settings >
     Privacy & Security after installing.
  3. Verify:  smartctl -a /dev/diskN   shows real SMART attributes.
  See the README "smartctl proxy" section for the full walkthrough.

The kext install needs reboots, so it can't be done from here. You can
install it now, or later — the proxy simply returns no real data until
the kext is loaded and the VM has been restarted.

EOF
    read -r -p "  Type 'install' to exit now and set the kext up, or press Enter to continue: " ans
    case "$ans" in
        install|Install|i|I)
            say "Exiting so you can install the kext and reboot."
            say "Re-run ./stand-up.sh afterwards — it picks up where it left off."
            exit 0 ;;
    esac
}

###############################################################################
# Interactive storage + network configuration
#
# Gathers the host-specific values that otherwise have to be hand-edited into
# protect-on-mac.conf — the physical disks to pass through (DISK_SERIALS),
# the virtual storage images to create (STORAGE_IMAGES), and the adapter to
# bridge (NIC_MAC) — then writes them into the conf and re-sources it so the
# rest of stand-up.sh sees the result.
###############################################################################

# GPT partition-type GUID identifying a Linux RAID member.
LINUX_RAID_GUID="A19D880F-05FC-4D3B-A006-743F0F84911E"

# One labelled field from `diskutil info` (whole disk or partition).
du_field() {
    diskutil info "$1" 2>/dev/null | awk -F': *' -v k="$2" '
        { lbl=$1; sub(/^[ \t]+/,"",lbl); sub(/[ \t]+$/,"",lbl) }
        lbl==k { print $2; exit }' || true
}

# External, physical whole-disk identifiers (diskN), one per line.
external_disk_ids() {
    diskutil list external physical 2>/dev/null \
        | awk '/^\/dev\/disk[0-9]+ /{ sub("/dev/","",$1); print $1 }' || true
}

# Partition identifiers (diskNsM) of a whole disk, one per line.
disk_partitions() {
    diskutil list "$1" 2>/dev/null \
        | awk -v d="$1" '{ for (i=1;i<=NF;i++) if ($i ~ "^"d"s[0-9]+$") print $i }' \
        || true
}

# ATA serial of a disk — smartctl first (authoritative; the same value
# start-protect-vm.sh matches against), diskutil UUID as a last resort.
disk_serial() {
    local dev="$1" s=""
    if command -v smartctl >/dev/null 2>&1; then
        s=$(smartctl -i "/dev/$dev" 2>/dev/null \
            | awk -F: '/Serial [Nn]umber/ {
                  gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit }' || true)
    fi
    [ -z "$s" ] && s=$(du_field "$dev" "Disk / Partition UUID")
    echo "$s"
}

# Read an mdadm 1.2 superblock (4096 bytes into a partition); if the magic
# matches, echo "level raid_disks uuid". Best-effort — any failure (no sudo,
# unreadable, different metadata version) yields nothing.
mdadm_superblock() {
    local part="$1" hex lvl rd
    hex=$(sudo dd if="/dev/r$part" bs=4096 skip=1 count=1 2>/dev/null \
          | od -An -tx1 -v 2>/dev/null | tr -d ' \n' || true)
    # magic 0xa92b4efc little-endian -> fc 4e 2b a9
    [ "${hex:0:8}" = "fc4e2ba9" ] || return 0
    # struct mdp_superblock_1: level u32@72, raid_disks u32@92, uuid@16
    local l=${hex:144:8} r=${hex:184:8}
    lvl=$(( 0x${l:6:2}${l:4:2}${l:2:2}${l:0:2} ))
    rd=$(( 0x${r:6:2}${r:4:2}${r:2:2}${r:0:2} ))
    echo "$lvl $rd ${hex:32:32}"
}

# md numeric level -> human name.
md_level_name() {
    case "$1" in
        0) echo raid0 ;; 1) echo raid1 ;; 4) echo raid4 ;;
        5) echo raid5 ;; 6) echo raid6 ;; 10) echo raid10 ;;
        *) echo "raid?" ;;
    esac
}

configure_storage_and_network() {
    echo
    say "------------------------------------------------------------"
    say " Storage + network configuration"
    say "------------------------------------------------------------"
    say "This writes the disk and network settings into:"
    say "  $CONF_FILE"
    echo

    local pass_serials=() image_entries=() nic_mac=""

    #########################################################################
    # Physical disk passthrough
    #########################################################################
    local ans ids=() id
    cat <<'EOF'
Physical disks can be passed through whole to the VM - for example the
drives from an existing UNVR - so the VM sees real hardware.

EOF
    # Pre-scan: list what is already attached so the prompt reflects
    # reality instead of asking blind. This is sudo-free (diskutil only);
    # the deeper RAID-superblock scan happens later, after consent.
    while IFS= read -r id; do [ -n "$id" ] && ids+=("$id"); done \
        < <(external_disk_ids)

    local want_disks=""
    if [ "${#ids[@]}" -gt 0 ]; then
        say "Detected ${#ids[@]} external disk(s) attached:"
        for id in "${ids[@]}"; do
            say "  /dev/$id  $(du_field "$id" "Disk Size")  $(du_field "$id" "Device / Media Name")"
        done
        echo
        read -r -p "  Pass physical disks through to the VM? [Y/n]: " ans
        case "$ans" in n|N) want_disks="" ;; *) want_disks="yes" ;; esac
    else
        say "No external disks are attached right now."
        read -r -p "  Pass physical disks through to the VM? [y/N]: " ans
        case "$ans" in
            y|Y)
                echo
                say "Connect ALL of those disks to this Mac now."
                read -r -p "  Press Enter once every disk is connected: " _
                ids=()
                while IFS= read -r id; do [ -n "$id" ] && ids+=("$id"); done \
                    < <(external_disk_ids)
                want_disks="yes"
                ;;
            *) want_disks="" ;;
        esac
    fi

    if [ -z "$want_disks" ]; then
        say "No physical disks - storage will be image files only."
    elif [ "${#ids[@]}" -eq 0 ]; then
        say "No external physical disks found - skipping passthrough."
    else
        echo
        say "Scanning disks (you may be asked for your macOS password -"
        say "reading RAID superblocks needs sudo)..."
        echo

        # Per-disk RAID info, in arrays parallel to ids[] (macOS bash is
        # 3.2 - no associative arrays):
        #   du_uuids[i] = space-separated md array UUIDs of ids[i]
        #   du_desc[i]  = human RAID description of ids[i]
        local du_uuids=() du_desc=()
        local i p uuids desc sb lvl rd uu
        for ((i=0; i<${#ids[@]}; i++)); do
            id="${ids[$i]}"
            uuids=""; desc=""
            for p in $(disk_partitions "$id"); do
                # Only Linux RAID partitions carry an md superblock.
                diskutil info "$p" 2>/dev/null \
                    | grep -qi "$LINUX_RAID_GUID" || continue
                sb=$(mdadm_superblock "$p") || true
                [ -n "$sb" ] || continue
                read -r lvl rd uu <<<"$sb"
                uuids="$uuids $uu"
                desc="$desc $(md_level_name "$lvl")/${rd}-disk"
            done
            du_uuids[$i]="${uuids# }"
            du_desc[$i]="${desc# }"
        done

        # Disks sharing any RAID UUID belong to the same array set; the
        # largest such set is the recommended passthrough group. rec_idx
        # holds those disks' indices, space-padded.
        local rec_idx=" " best_n=0 u all_uuids n grp
        all_uuids=$(printf '%s\n' "${du_uuids[@]}" | tr ' ' '\n' \
                    | grep -v '^$' | sort -u || true)
        for u in $all_uuids; do
            n=0; grp=" "
            for ((i=0; i<${#ids[@]}; i++)); do
                case " ${du_uuids[$i]} " in
                    *" $u "*) grp="$grp$i "; n=$((n+1)) ;;
                esac
            done
            if [ "$n" -gt "$best_n" ]; then best_n=$n; rec_idx="$grp"; fi
        done

        echo
        if [ "$best_n" -ge 2 ]; then
            say "These ${best_n} disks look like one array (a UNVR set)."
            say "I think these are the disks you want - confirm each below:"
        else
            say "No multi-disk array detected. Listed every external disk -"
            say "confirm the ones to pass through:"
            rec_idx=" "
            for ((i=0; i<${#ids[@]}; i++)); do rec_idx="$rec_idx$i "; done
        fi
        echo

        # Confirm each disk, showing full specs.
        for ((i=0; i<${#ids[@]}; i++)); do
            id="${ids[$i]}"
            local size model bus serial recommended="" def="n"
            size=$(du_field "$id" "Disk Size")
            model=$(du_field "$id" "Device / Media Name")
            bus=$(du_field "$id" "Protocol")
            serial=$(disk_serial "$id")
            case "$rec_idx" in
                *" $i "*) recommended=" [recommended]"; def="y" ;;
            esac
            echo "  Disk $((i+1)): /dev/$id$recommended"
            echo "    Model    : ${model:-unknown}"
            echo "    Size     : ${size:-unknown}"
            echo "    Bus      : ${bus:-unknown}"
            echo "    Serial   : ${serial:-UNREADABLE}"
            [ -n "${du_desc[$i]}" ] \
                && echo "    RAID     : ${du_desc[$i]}"
            if [ -z "$serial" ]; then
                echo "    (no serial - cannot pass this disk through;"
                echo "     set up the smartctl proxy and re-run)"
            else
                read -r -p "    Pass this disk through? [$def]: " ans
                ans="${ans:-$def}"
                case "$ans" in
                    y|Y) pass_serials+=("$serial") ;;
                esac
            fi
            echo
        done
    fi

    #########################################################################
    # Virtual storage images
    #########################################################################
    echo
    read -r -p "  Also create virtual storage image disk(s)? [y/N]: " ans
    case "$ans" in
        y|Y)
            local count=""
            while :; do
                read -r -p "  How many image disks? [1]: " count
                count="${count:-1}"
                [[ "$count" =~ ^[1-9][0-9]*$ ]] && break
                echo "  Enter a positive whole number."
            done
            local i
            for ((i=1; i<=count; i++)); do
                image_entries+=( "\${VM_DATA_DIR}/storage-$(printf '%02d' "$i").qcow2|storage-$(printf '%03d' "$i")" )
            done
            say "Will create $count image disk(s); sizes are asked later."
            ;;
    esac

    if [ "${#pass_serials[@]}" -eq 0 ] && [ "${#image_entries[@]}" -eq 0 ]; then
        say "WARNING: no storage configured. The VM needs at least one data"
        say "disk to build its recording array — you can add some to"
        say "$CONF_FILE later."
    fi

    #########################################################################
    # Network adapter
    #########################################################################
    echo
    say "Choose the network adapter to bridge the VM onto your LAN."
    local hw_ports=() line port=""
    while IFS= read -r line; do hw_ports+=("$line"); done < <(
        networksetup -listallhardwareports 2>/dev/null
    )
    local devs=() macs=() names=() name="" dev=""
    # The primary default-route interface — what NIC_MAC="auto" would
    # pick right now. Shown next to option 1 so the user knows what auto
    # resolves to on this host today.
    local primary_iface
    primary_iface=$(route -n get default 2>/dev/null \
        | awk '/^[[:space:]]*interface:/ { print $2; exit }')
    echo "  1) auto — primary default-route interface" \
         "${primary_iface:+(currently $primary_iface)}" \
         "[Recommended]"
    echo "       Bridges through whichever adapter currently owns the"
    echo "       LAN route — roams cleanly between dock/Wi-Fi/etc."
    local idx=2
    # networksetup prints 3-line stanzas: Hardware Port / Device / Ethernet
    # Address. That "Ethernet Address" is the BURNED-IN hardware MAC. On
    # Wi-Fi, macOS "Private Wi-Fi Address" puts a different, randomized MAC
    # on the wire — but it is PER-SSID and rotates when the Mac roams
    # between networks. NIC_MAC just identifies which en* device to bridge
    # through, so it must be STABLE: we record the hardware MAC and only
    # surface the live MAC for context. resolve_nic_by_mac in
    # start-protect-vm.sh will match either form at runtime.
    local hp="" hw_mac="" live_mac="" hw_lc=""
    for line in "${hw_ports[@]}"; do
        case "$line" in
            "Hardware Port: "*)   hp="${line#Hardware Port: }" ;;
            "Device: "*)          dev="${line#Device: }" ;;
            "Ethernet Address: "*)
                hw_mac="${line#Ethernet Address: }"
                if [ -n "$dev" ] && [ "$hw_mac" != "N/A" ] && [ -n "$hw_mac" ]; then
                    live_mac=$(ifconfig "$dev" 2>/dev/null \
                        | awk '/[ \t]ether /{ print tolower($2); exit }')
                    hw_lc=$(echo "$hw_mac" | tr '[:upper:]' '[:lower:]')
                    names+=("$hp"); devs+=("$dev"); macs+=("$hw_mac")
                    echo "  $idx) $dev  $hp  $hw_mac"
                    if [ -n "$live_mac" ] && [ "$live_mac" != "$hw_lc" ]; then
                        echo "       in use: $live_mac" \
                             "(rotates per Wi-Fi network)"
                    fi
                    case "$hp" in
                        *Wi-Fi*|*AirPort*)
                            echo "       not recommended — bridging over" \
                                 "Wi-Fi is unreliable" ;;
                    esac
                    idx=$((idx+1))
                fi
                dev=""; hp="" ;;
        esac
    done

    if [ "${#macs[@]}" -eq 0 ]; then
        # No adapters at all — fall back to auto (the safest default).
        nic_mac="auto"
        say "No specific adapters found — using auto (primary default route)."
    else
        local pick="" max=$((${#macs[@]} + 1))
        while :; do
            read -r -p "  Adapter number [1]: " pick
            pick="${pick:-1}"
            if [ "$pick" = "1" ]; then
                nic_mac="auto"
                say "selected auto" \
                    "${primary_iface:+(currently resolves to $primary_iface)}"
                break
            fi
            if [[ "$pick" =~ ^[0-9]+$ ]] \
               && [ "$pick" -ge 2 ] && [ "$pick" -le "$max" ]; then
                nic_mac="${macs[$((pick-2))]}"
                say "selected ${names[$((pick-2))]} ($nic_mac)"
                break
            fi
            echo "  Enter a number between 1 and $max."
        done
    fi

    #########################################################################
    # Write the conf
    #########################################################################
    local serials_block="DISK_SERIALS=(" images_block="STORAGE_IMAGES=("
    if [ "${#pass_serials[@]}" -gt 0 ]; then
        local s
        for s in "${pass_serials[@]}"; do
            serials_block="$serials_block"$'\n'"    \"$s\""
        done
        serials_block="$serials_block"$'\n'")"
    else
        serials_block="$serials_block)"
    fi
    if [ "${#image_entries[@]}" -gt 0 ]; then
        local e
        for e in "${image_entries[@]}"; do
            images_block="$images_block"$'\n'"    \"$e\""
        done
        images_block="$images_block"$'\n'")"
    else
        images_block="$images_block)"
    fi

    NEW_SERIALS="$serials_block" NEW_IMAGES="$images_block" \
    NEW_NIC="${nic_mac:-aa:bb:cc:dd:ee:ff}" \
        perl -0pi -e '
            s/DISK_SERIALS=\([^)]*\)/$ENV{NEW_SERIALS}/;
            s/STORAGE_IMAGES=\([^)]*\)/$ENV{NEW_IMAGES}/;
            s/^NIC_MAC=.*$/NIC_MAC="$ENV{NEW_NIC}"/m;
        ' "$CONF_FILE" \
        || die "failed to update $CONF_FILE"

    say "wrote storage + network settings to $CONF_FILE"
    # Re-source so the rest of stand-up.sh sees the new values.
    # shellcheck source=/dev/null
    source "$CONF_FILE"
    STORAGE_IMAGES=("${STORAGE_IMAGES[@]:-}")
    echo
}

ensure_homebrew
ensure_brew_cmd qemu-system-aarch64 qemu
ensure_brew_cmd socat socat

for bin in qemu-system-aarch64 qemu-img curl shasum socat; do
    command -v "$bin" >/dev/null 2>&1 || die "$bin not found — 'brew install qemu socat'"
done
if [ ! -f "$EFI_CODE" ]; then
    say "EFI firmware not found at:"
    say "  $EFI_CODE"
    die "install qemu (brew install qemu) or set EFI_CODE in the config"
fi

ensure_sudoers

mkdir -p "$VM_DATA_DIR" "$ISO_DIR"

maybe_setup_smartctl_proxy

configure_storage_and_network

###############################################################################
# 1. Debian netinst ISO — download + verify, cached
###############################################################################

verify_iso() {
    [ -f "$ISO_PATH" ] || return 1
    local want got
    want=$(awk -v f="$ISO_NAME" '$2=="./"f || $2==f {print $1; exit}' \
           "$ISO_DIR/SHA256SUMS" 2>/dev/null)
    [ -n "$want" ] || return 1
    got=$(shasum -a 256 "$ISO_PATH" | awk '{print $1}')
    [ "$want" = "$got" ]
}

# A locally-supplied ISO + SHA256SUMS pair verifies entirely offline: the
# sums are fetched only when the cached pair doesn't verify (file absent,
# partial download, or mismatch). The fetch goes to a temp file first so an
# unreachable mirror can't clobber a usable cached SHA256SUMS.
if ! verify_iso; then
    say "fetching SHA256SUMS"
    curl -fSL --connect-timeout 15 -o "$ISO_DIR/SHA256SUMS.tmp" \
        "$ISO_BASE/SHA256SUMS" \
        || die "could not fetch SHA256SUMS — check DEBIAN_VERSION ($DEBIAN_VERSION)"
    mv -f "$ISO_DIR/SHA256SUMS.tmp" "$ISO_DIR/SHA256SUMS"
fi

if verify_iso; then
    say "ISO already present and verified:"
    say "  $ISO_PATH"
else
    say "downloading $ISO_NAME (~$( [ "$DEBIAN_ARCH" = arm64 ] && echo 400MB || echo 650MB ))"
    say "  to supply the ISO yourself instead, drop it here and re-run"
    say "  (it gets verified, not re-downloaded):"
    say "  $ISO_PATH"
    # -C - resumes a partial transfer, so a dropped connection to a slow
    # mirror picks up where it left off instead of starting over.
    curl -fSL -C - --connect-timeout 15 -o "$ISO_PATH" "$ISO_BASE/$ISO_NAME" \
        || die "ISO download failed (re-run to resume, or fetch it manually)"
    if ! verify_iso; then
        say "ISO SHA256 mismatch — the download is corrupt. Delete it"
        say "and re-run to download it again:"
        say "  $ISO_PATH"
        die "ISO verification failed"
    fi
    say "ISO verified"
fi

###############################################################################
# 2. OS disk
###############################################################################

# Tracks whether the OS disk is brand new. A fresh OS disk must be paired
# with a fresh UEFI varstore (see section 3): a varstore left over from a
# previous install carries a stale NVRAM BootOrder — typically pinned to
# the edk2 Internal Shell — which makes every boot drop to the UEFI shell
# instead of falling back to \EFI\BOOT\BOOTAA64.EFI on the new disk.
OS_DISK_FRESH=0

if [ -f "$VM_DISK" ]; then
    say "OS disk already exists:"
    say "  $VM_DISK"
    read -r -p "  Reuse it (r) / recreate from scratch (c) / abort (a)? [r]: " ans
    case "$ans" in
        c|C) rm -f "$VM_DISK"
             qemu-img create -f qcow2 "$VM_DISK" "$VM_DISK_SIZE" >/dev/null
             OS_DISK_FRESH=1
             say "recreated the OS disk ($VM_DISK_SIZE)" ;;
        a|A) die "aborted by user" ;;
        *)   say "reusing the existing OS disk" ;;
    esac
else
    qemu-img create -f qcow2 "$VM_DISK" "$VM_DISK_SIZE" >/dev/null
    OS_DISK_FRESH=1
    say "created OS disk ($VM_DISK_SIZE):"
    say "  $VM_DISK"
fi

###############################################################################
# 3. UEFI variable store
###############################################################################
#
# Recreate the varstore whenever the OS disk is fresh, so the new install
# starts with empty NVRAM. With no boot entries, edk2 enumerates every
# disk and auto-boots the removable-media path \EFI\BOOT\BOOTAA64.EFI —
# no manual disk pick at the UEFI shell.

if [ "$OS_DISK_FRESH" -eq 1 ] && [ -f "$EFI_VARS" ]; then
    say "OS disk is fresh — recreating the UEFI vars store to clear"
    say "stale NVRAM"
    rm -f "$EFI_VARS"
fi
if [ ! -f "$EFI_VARS" ]; then
    say "creating UEFI vars store (64 MiB):"
    say "  $EFI_VARS"
    dd if=/dev/zero of="$EFI_VARS" bs=1m count=64 status=none
fi

###############################################################################
# 4. Blank data disks (one per STORAGE_IMAGES entry: "path|serial")
###############################################################################
#
# install-protect-baremetal.sh rejects any data disk smaller than 128 GiB,
# so the size prompt enforces that minimum. qcow2 files are sparse — a
# 150G image costs almost nothing on disk until the VM writes to it — so
# there is no penalty for sizing generously.

MIN_DATA_GB=128

# Echo the size in whole GiB if the argument parses as <int>G or <int>T,
# otherwise echo nothing.
data_size_gb() {
    local s="$1" num
    case "$s" in
        *[Gg]) num="${s%[GgTt]}"; [[ "$num" =~ ^[0-9]+$ ]] && echo "$num" ;;
        *[Tt]) num="${s%[GgTt]}"; [[ "$num" =~ ^[0-9]+$ ]] && echo $((num * 1024)) ;;
    esac
}

DATA_SIZE=""
for entry in "${STORAGE_IMAGES[@]}"; do
    [ -n "$entry" ] || continue
    img="${entry%%|*}"
    if [ -f "$img" ]; then
        say "data disk exists, leaving as-is:"
        say "  $img"
        continue
    fi
    if [ -z "$DATA_SIZE" ]; then
        say "Each data disk needs at least ${MIN_DATA_GB}G. qcow2 files are"
        say "sparse, so a generous size (150G+) costs nothing on disk"
        say "until the VM actually writes to it."
        while :; do
            read -r -p "  Size for each new data disk [150G]: " DATA_SIZE
            DATA_SIZE="${DATA_SIZE:-150G}"
            gb="$(data_size_gb "$DATA_SIZE")"
            if [ -n "$gb" ] && [ "$gb" -ge "$MIN_DATA_GB" ]; then
                break
            fi
            echo "  '$DATA_SIZE' is too small or malformed — need at least"
            echo "  ${MIN_DATA_GB}G per data disk (e.g. 150G or 2T)."
            DATA_SIZE=""
        done
    fi
    qemu-img create -f qcow2 "$img" "$DATA_SIZE" >/dev/null
    say "created blank data disk ($DATA_SIZE):"
    say "  $img"
done

###############################################################################
# 5. Boot the Debian installer
###############################################################################

# Build the preseeded installer. The Debian install is unattended: this
# embeds preseed.cfg into the netinst's initrd and boots the installer
# kernel directly. QEMU's EDK2 firmware honours -kernel/-initrd/-append via
# fw_cfg, so the installer still comes up in a UEFI environment (and thus
# installs a UEFI bootloader) — no boot-menu editing, no interactive steps.

# Prompt for the VM's root password (twice, hidden) and hash it here.
# The plaintext is never written to the config file and never appears in
# the process list (openssl reads it on stdin). The resulting SHA-512
# crypt hash is appended to the preseed at build time.
echo
say "Set the root password for the VM. It is used to log in at the"
say "console and over SSH. Entered twice, not echoed."
while :; do
    printf '[stand-up]   root password: ' >&2
    read -r -s _pw1; echo >&2
    printf '[stand-up]   confirm:       ' >&2
    read -r -s _pw2; echo >&2
    if [ -z "$_pw1" ]; then
        say "  password is empty — try again"
    elif [ "$_pw1" != "$_pw2" ]; then
        say "  passwords do not match — try again"
    else
        break
    fi
done
ROOT_PASSWORD_CRYPTED=$(printf '%s\n' "$_pw1" | openssl passwd -6 -stdin)
unset _pw1 _pw2
case "$ROOT_PASSWORD_CRYPTED" in
    '$'*) ;;
    *) die "failed to hash the root password (openssl passwd -6)" ;;
esac

PRESEED_SRC="$SCRIPT_DIR/preseed.cfg"
[ -f "$PRESEED_SRC" ] || die "preseed template not found: $PRESEED_SRC"
# Carried in the initrd alongside preseed.cfg; the preseed late_command
# installs them into the target so the VM auto-runs start-here.sh on its
# first boot (see first-boot.sh / autologin.conf for what they do).
AUTOLOGIN_SRC="$SCRIPT_DIR/autologin.conf"
FIRSTBOOT_SRC="$SCRIPT_DIR/first-boot.sh"
[ -f "$AUTOLOGIN_SRC" ] || die "missing: $AUTOLOGIN_SRC"
[ -f "$FIRSTBOOT_SRC" ] || die "missing: $FIRSTBOOT_SRC"

INST_DIR="$VM_DATA_DIR/installer"
INST_KERNEL="$INST_DIR/vmlinuz"
INST_INITRD="$INST_DIR/initrd-preseed.gz"
mkdir -p "$INST_DIR"

# The Debian netinst is a hybrid ISO that macOS hdiutil often refuses to
# mount ("no mountable file systems"). macOS `tar` is bsdtar, and its
# libarchive backend reads ISO9660 directly — so pull the two files we
# need straight out of the image, no mounting required. --strip-components
# drops the install.a64/ prefix so they land directly in INST_DIR.
say "Extracting the installer kernel + initrd from the netinst ISO..."
rm -f "$INST_KERNEL" "$INST_DIR/initrd.gz" "$INST_INITRD"
tar -xf "$ISO_PATH" -C "$INST_DIR" --strip-components=1 \
    install.a64/vmlinuz install.a64/initrd.gz 2>/dev/null || true
[ -f "$INST_KERNEL" ] && [ -f "$INST_DIR/initrd.gz" ] \
    || die "installer kernel not found at install.a64/ on the netinst ISO"

say "Embedding preseed.cfg into the installer initrd..."
PS_TMP=$(mktemp -d)
cp "$PRESEED_SRC"   "$PS_TMP/preseed.cfg"
cp "$AUTOLOGIN_SRC" "$PS_TMP/autologin.conf"
cp "$FIRSTBOOT_SRC" "$PS_TMP/first-boot.sh"
# The root password line is appended here, from the config — kept out of
# the committed preseed.cfg template.
echo "d-i passwd/root-password-crypted password $ROOT_PASSWORD_CRYPTED" \
    >> "$PS_TMP/preseed.cfg"
cp "$INST_DIR/initrd.gz" "$INST_INITRD"
# Files extracted from the ISO carry its read-only mode (0444); make the
# working copy writable so the cpio archive can be appended to it.
chmod u+w "$INST_INITRD"
# A Linux initrd is concatenated gzipped cpio archives; appending one
# that carries /preseed.cfg makes debian-installer pick it up
# automatically. autologin.conf and first-boot.sh ride along in the same
# archive — the preseed late_command copies them into the target.
( cd "$PS_TMP" && printf '%s\n' preseed.cfg autologin.conf first-boot.sh \
    | cpio -o -H newc 2>/dev/null | gzip ) >> "$INST_INITRD"
rm -rf "$PS_TMP"
say "Preseeded installer ready under $INST_DIR"

cat <<EOF

[stand-up] Ready to boot the Debian $DEBIAN_VERSION installer.

  - The install is fully automated by preseed — no input needed.
    It runs on this terminal (serial console); just watch.

  - It partitions the single virtio disk (the data disks are not
    attached), installs a minimal Debian (SSH server only), sets the
    root password you just entered, and installs the bootloader to the
    EFI removable-media path so the VM boots on its own.

  - When the install finishes the installer reboots. QEMU is launched
    with -no-reboot for this step, so that reboot makes QEMU exit on
    its own — the installer runs exactly once. You don't need to do
    anything; just wait for the shell prompt to return.

EOF
read -r -p "Press Enter to launch, or Ctrl-C to abort: " _

# -no-reboot: QEMU re-runs whatever -kernel points at on every guest
# reset, so the installer's final reboot would just relaunch the
# installer. -no-reboot makes QEMU exit on that reboot instead — the
# installer runs once, then the next normal start (start-protect-vm.sh,
# no -kernel) boots the installed system from its EFI bootloader.
qemu-system-aarch64 \
    -machine virt,accel=hvf \
    -cpu host \
    -smp "$VM_CPUS" \
    -m "$VM_RAM" \
    -no-reboot \
    -kernel "$INST_KERNEL" \
    -initrd "$INST_INITRD" \
    -append "console=ttyAMA0 auto=true priority=critical" \
    -drive if=pflash,format=raw,unit=0,file="$EFI_CODE",readonly=on \
    -drive if=pflash,format=raw,unit=1,file="$EFI_VARS" \
    -drive if=virtio,file="$VM_DISK",format=qcow2 \
    -device virtio-scsi-pci,id=scsi0 \
    -drive if=none,id=instcd,file="$ISO_PATH",format=raw,media=cdrom,readonly=on \
    -device scsi-cd,bus=scsi0.0,drive=instcd \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -nographic

###############################################################################
# 6. Hand off
###############################################################################

cat <<EOF

[stand-up] Installer session ended.

If the Debian install completed, the VM is ready to run. The storage and
network settings you chose earlier are already written to:
  $CONF_FILE
so there is nothing left to hand-edit. To re-run that step (different
disks, a different adapter), just run stand-up.sh again.

On its FIRST boot the VM auto-logs in on the console and runs start-here.sh,
which unpacks the project and — after a 30s countdown — runs the baremetal
installer on its own. The installer auto-reboots when done, leaving the VM
at a login prompt that shows the setup-portal URL. So from here it is
hands-off; just watch the console.

EOF

# Offer to launch the VM right now, closing the loop: stand-up.sh ->
# start-protect-vm.sh -> first boot -> start-here.sh -> installer ->
# reboot -> portal-ready login prompt, with no further commands.
START_VM="$SCRIPT_DIR/start-protect-vm.sh"
if [ -x "$START_VM" ]; then
    read -r -p "[stand-up] Start the VM now? [Y/n]: " ans
    case "$ans" in
        n|N) say "Not started. Launch it yourself with:"
             say "  $START_VM $VM_DATA_DIR" ;;
        *)   say "starting the VM — this terminal becomes its console..."
             exec "$START_VM" "$VM_DATA_DIR" ;;
    esac
else
    say "start-protect-vm.sh not found next to stand-up.sh. Start the VM"
    say "later with:  /path/to/start-protect-vm.sh $VM_DATA_DIR"
fi
