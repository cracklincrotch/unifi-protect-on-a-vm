# Quick Start

The 10-minute version. For the full reference, see [README.md](README.md).

## Is this for you?

- You're running UniFi Protect and/or Access
- You have (or want) more performance than a UNVR provides — more RAM, faster disk for the database, faster CPU
- You have an **ARM64** host: Apple Silicon Mac, Raspberry Pi 5, or similar. **Intel Macs will not work** — the UniFi binaries are ARM64-only.
- You're comfortable with the Linux command line and basic QEMU concepts

## What you'll need

- ARM64 host with at least 8GB RAM
- Storage for VM and recordings (internal NVMe for the VM and postgres; HDDs/SSDs in a DAS for bulk recordings)
- 30-60 minutes for a fresh install; +30 minutes if migrating from a real UNVR

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
cp protect-on-mac.conf.example protect-on-mac.conf
$EDITOR protect-on-mac.conf
```

At minimum, set `NIC_MAC` to the MAC of your wired ethernet adapter (find with `networksetup -listallhardwareports`). Disk serials can be added later.

### 3. Create VM disk and boot Debian installer

```bash
source ./protect-on-mac.conf
mkdir -p "$VM_DATA_DIR"
qemu-img create -f qcow2 "$VM_DISK" 32G
dd if=/dev/zero of="$EFI_VARS" bs=1M count=64

# Download Debian 11 ARM64 netinst ISO to $VM_DATA_DIR first, then:
DEBIAN_ISO="$VM_DATA_DIR/debian-11.x.0-arm64-netinst.iso"

qemu-system-aarch64 \
    -machine virt,accel=hvf \
    -cpu host -smp "$VM_CPUS" -m "$VM_RAM" \
    -drive if=pflash,format=raw,unit=0,file="$EFI_CODE",readonly=on \
    -drive if=pflash,unit=1,file="$EFI_VARS" \
    -drive if=virtio,file="$VM_DISK",format=qcow2 \
    -drive if=none,id=cd,file="$DEBIAN_ISO",format=raw,media=cdrom \
    -device virtio-scsi-pci,id=scsi0 \
    -device scsi-cd,bus=scsi0.0,drive=cd \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -nographic
```

At the GRUB menu, press `<Tab>` and add `console=ttyAMA0` so the installer shows on the serial console.

Install **minimal Debian** — SSH server only, no desktop. Either let it use the whole disk for `/`, or partition with 2GB swap + rest for `/`.

### 4. Create the scripts ISO and boot the VM with it

```bash
./make-scripts-iso.sh

# Boot with the scripts ISO attached
qemu-system-aarch64 \
    -machine virt,accel=hvf \
    -cpu host -smp "$VM_CPUS" -m "$VM_RAM" \
    -drive if=pflash,format=raw,unit=0,file="$EFI_CODE",readonly=on \
    -drive if=pflash,unit=1,file="$EFI_VARS" \
    -drive if=virtio,file="$VM_DISK",format=qcow2 \
    -device virtio-scsi-pci,id=scsi0 \
    -drive if=none,id=scripts,file="$SCRIPTS_ISO",format=raw,media=cdrom \
    -device scsi-cd,bus=scsi0.0,drive=scripts \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -nographic
```

### 5. Inside the VM, install UniFi

Login as root, then:

```bash
mkdir -p /mnt/protect-on-mac
mount /dev/sr0 /mnt/protect-on-mac
cp /mnt/protect-on-mac/*.sh /root/
chmod +x /root/*.sh
umount /mnt/protect-on-mac

bash /root/install-protect-baremetal.sh
```

This takes ~30 minutes. When done, shut down the VM: `systemctl poweroff`.

### 6. Boot with bridged networking from the host

```bash
./start-protect-vm.sh
```

Visit `https://<VM-IP>` and go through the initial UniFi setup.

## Migrating from a real UNVR

After step 5 above (UniFi installed, VM shut down):

1. **On the UNVR web UI**: back up Protect and Access. Download the backup files.
2. **Do NOT remove cameras from the UNVR** before backing up — the backup includes camera identity.
3. **Cleanly shut down the UNVR** via its web UI.
4. **Boot the new VM** with `./start-protect-vm.sh`.
5. **In the VM web UI**: restore both backups. Cameras will re-adopt over the next few minutes.
6. **Move the UNVR disks** to your DAS. Inside the VM: `/root/mount-storage.sh import` to attach existing recordings.
7. **(Optional but recommended)** Migrate postgres to SSD for big speed gains:
   ```bash
   /root/mount-storage.sh postgres-migrate /dev/sdX
   ```

## Common operations

```bash
# Snapshot before risky changes (VM keeps running, pauses briefly)
./snapshot.sh create-auto pre-update

# Update UniFi software
ssh root@<VM-IP> /root/unifi-update.sh --all

# Roll back if something broke
./install-launchd.sh stop    # or: ssh root@<VM-IP> systemctl poweroff
./snapshot.sh rollback       # interactive picker
./install-launchd.sh start

# Auto-start VM at host boot
./install-launchd.sh install /path/to/start-protect-vm.sh
```

## When something goes wrong

- **VM won't boot**: attach the serial console with `./attach-console.sh` and see what's happening.
- **Cameras don't reconnect**: give them 5-10 minutes. If still missing, re-adopt in the Protect UI.
- **Search/UI is slow**: migrate postgres to a dedicated SSD (step 7 of migration above).
- **An update broke things**: `./snapshot.sh rollback` to the pre-update snapshot.
- **Something not covered here**: see [README.md](README.md) for the full reference.

## Limitations to know about

- This is **not officially supported by Ubiquiti**. Use at your own risk.
- A UniFi OS update could introduce new services that need to be masked. Snapshot before every update.
- Initial Debian install is hands-on (not yet automated).
- Intel Macs will not work — ARM64 host required.

For the complete reference, including architecture details, hardware spoofing, troubleshooting, and the reverse-migration path back to a real UNVR, see [README.md](README.md).
