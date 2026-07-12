# Quick Start

The 10-minute version. For the full reference, see [README.md](README.md).

## Is this for you?

- You're running UniFi Protect and/or Access
- You have (or want) more performance than a UNVR provides — more RAM, faster disk for the database, faster CPU
- You have an **ARM64** host: Apple Silicon Mac, Raspberry Pi 5, or similar. **Intel Macs will not work** — the UniFi binaries are ARM64-only.
- You're comfortable with the Linux command line and basic QEMU concepts

## What you'll need

- ARM64 host with at least 8GB RAM
- Storage for VM and recordings (internal NVMe for the VM's `vda`, which also serves postgres at runtime; HDDs in a DAS for bulk recordings)
- 30-60 minutes for a fresh install; +30 minutes if migrating from a real UNVR

## Repository layout

After cloning, the project is split by where things run:

```
host/      runs on the macOS host  — start-protect-vm.sh, stand-up.sh, ...
vm/        copied into the VM      — installers/ + the storage subsystem
capture/   diagnostic capture tools
```

Run all the commands below from inside the cloned directory. Host-side
commands live in `host/`; VM-side files live in `vm/`.

## Install (fresh)

### 1. Host prerequisites (macOS)

```bash
brew install qemu wget jq smartmontools socat

# Allow QEMU to access raw disks without password
sudo visudo -f /etc/sudoers.d/qemu-vm
# Add (replace 'yourusername'):
#   yourusername ALL=(root) NOPASSWD: /opt/homebrew/bin/qemu-system-aarch64
```

### 2. Clone and configure

```bash
git clone https://github.com/cracklincrotch/unifi-protect-on-a-vm.git
cd unifi-protect-on-a-vm
cp host/protect-on-mac.conf.example host/protect-on-mac.conf
$EDITOR host/protect-on-mac.conf
```

At minimum, set `VM_DATA_DIR` and `STORAGE_IMAGES` (the data disks to
create). Set `NIC_MAC` to the MAC of your wired ethernet adapter (find
with `networksetup -listallhardwareports`) before the bridged boot —
disk serials can be added later.

### 3. Create the VM and install Debian

`stand-up.sh` downloads + verifies the Debian netinst ISO, creates the
OS disk, the UEFI varstore, and the blank data disks, then boots the
Debian installer on the serial console:

```bash
cd host
./stand-up.sh
```

**At the Debian boot menu** (the very first screen — "Install / Graphical
install / ..."), before installing: highlight **Install**, press **`e`**,
append ` grub-installer/force-efi-extra-removable=true` to the end of the
`linux` line, then **`Ctrl-X`** to boot. This forces GRUB to install the
removable-media boot file (`\EFI\BOOT\BOOTAA64.EFI`) so the VM boots on
its own — the matching installer question is hidden at standard priority,
so this preseed is the only reliable way to set it. Skip it and the VM
drops to a UEFI shell on every boot.

Install a minimal Debian (SSH server only, no desktop). When the install
finishes and the VM reboots into the installer again, quit QEMU with
`Ctrl-A` then `X`.

### 4. Build the scripts ISO and boot the VM

```bash
./make-scripts-iso.sh        # bundles the vm/ tree into an ISO
./start-protect-vm.sh        # boots the VM, attaching the ISO as /dev/sr0
```

### 5. Inside the VM, install UniFi

Log in as root (a fresh Debian has no `sudo` — run everything bare), mount
the scripts ISO, and run `start-here.sh` — it unpacks the project and runs
the installer (`install-protect-baremetal.sh`, ~30 min; its final phase
installs the storage subsystem too):

```bash
mkdir -p /mnt/protect-on-mac
mount /dev/sr0 /mnt/protect-on-mac
bash /mnt/protect-on-mac/start-here.sh
```

When done, shut down the VM: `systemctl poweroff`.

### 6. Boot with bridged networking from the host

```bash
./start-protect-vm.sh
```

Visit `https://<VM-IP>` and go through the initial UniFi setup.

## Migrating from a real UNVR

After step 5 above (UniFi installed, VM shut down):

1. **On the UNVR web UI**: back up Protect and Access. Either download the backup files locally, or use your Ubiquiti (UI) account's cloud backup — cloud backups appear automatically in the new VM's restore list when it's signed into the same account.
2. **Do NOT remove cameras from the UNVR** before backing up — the backup includes camera identity.
3. **Boot the new VM** with `./start-protect-vm.sh` and sign it into the same Ubiquiti account.
4. **Confirm the backup is reachable from the new VM** — visible in its restore list for a cloud backup, or the downloaded file in hand. Do not proceed until you've seen it.
5. **Cleanly shut down the UNVR** via its web UI, then **remove it from the network** — if it powers back on while connected it will fight the VM for the cameras.
6. **In the VM web UI**: restore both backups. Cameras will re-adopt over the next few minutes.
7. **Move the UNVR disks** to your DAS. Inside the VM: `/root/vm/installers/mount-storage.sh import` to attach existing recordings.
8. **Postgres performance is automatic** — nothing to run. As long as the VM's `vda` qcow2 is on solid-state storage (host NVMe), Protect keeps its database on `vda` (via its own `/ssd1` detection), which is what makes the UI snappy.

## Common operations

All host-side commands run from the `host/` directory:

```bash
# Snapshot before risky changes (VM keeps running, pauses briefly)
./snapshot.sh create-auto pre-update

# Update UniFi software
ssh root@<VM-IP> /root/vm/installers/update-unifi.sh --all

# Roll back if something broke
./install-launchd.sh stop    # or: ssh root@<VM-IP> systemctl poweroff
./snapshot.sh rollback       # interactive picker
./install-launchd.sh start

# Auto-start VM at host boot
./install-launchd.sh install /path/to/host/start-protect-vm.sh
```

## When something goes wrong

- **VM won't boot**: attach the serial console with `./attach-console.sh` and see what's happening.
- **VM drops to the UEFI shell**: the varstore has a stale boot order — recreate `$EFI_VARS` (delete it, `dd` a fresh 64 MiB file) while the VM is off. `stand-up.sh` does this automatically when it recreates the OS disk.
- **Cameras don't reconnect**: give them 5-10 minutes. If still missing, re-adopt them. If the Protect web UI won't handle the re-adoption (it sometimes won't), use the Protect mobile app instead — it can adopt cameras the web UI can't.
- **Search/UI is slow**: make sure the VM's `vda` qcow2 is on solid-state storage (host NVMe) — Protect keeps its database on `vda`, so a slow `vda` means a slow UI.
- **An update broke things**: `./snapshot.sh rollback` to the pre-update snapshot.
- **macOS host claims it's out of space but Disk Utility shows free room**: APFS local Time Machine snapshots silently pin space that the GUI counts as "free" (it's actually "purgeable"). Check actual headroom with `df -h /`. If much smaller than the GUI claims, thin the snapshots: `sudo tmutil thinlocalsnapshots / 200000000000 4`. See README "Recovery from common failures" for detail.
- **Protect won't start after the host was forcibly stopped**: postgres@14-protect left a stale `postmaster.pid`. Inside the VM, `journalctl -u postgresql@14-protect` shows `pid file is invalid`. Fix: `rm -f /data/postgresql/14/protect/data/postmaster.pid && systemctl start postgresql@14-protect && systemctl start unifi-protect`. Prefer `systemctl poweroff` inside the VM over killing the QEMU process.
- **First-boot log says "PostgreSQL running with /data/ but /srv/ has the real DB"**: that's expected. On a fresh install the DB initializes on `/data/` before the array exists; on the next boot after you create the array in the web UI, it migrates to `/srv/`. Runs once.
- **One disk shows as "QEMU HARDDISK" in the Storage pane on first render**: a race in the smartctl shim during initial discovery. Reload the page; all four disks will normalize to `UniFi Protect VM Disk`.
- **Something not covered here**: see [README.md](README.md) for the full reference.

## Limitations to know about

- This is **not officially supported by Ubiquiti**. Use at your own risk.
- A UniFi OS update could introduce new services that need to be masked. Snapshot before every update.
- Intel Macs will not work — ARM64 host required.

For the complete reference, including architecture details, hardware spoofing, troubleshooting, and the reverse-migration path back to a real UNVR, see [README.md](README.md).
