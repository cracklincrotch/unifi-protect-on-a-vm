# UniFi Protect on a VM

Run UniFi Protect (and Access) in a Debian VM on macOS or Linux, replacing or supplementing a Ubiquiti UNVR. Storage lives in a USB DAS, the Protect software stack runs in a Debian 11 (Bullseye) ARM64 VM, and the host can be any reasonably modern ARM-based system — Apple silicon Mac, Raspberry Pi 5, an ARM server, etc.

This is a working setup running UniFi Protect with smart detection, face recognition, and UniFi Access. The scripts and configuration in this repo were fully vibe-coded with Claude, which dramatically sped up the process and produced thorough inline documentation along the way.

> **In a hurry?** [QUICKSTART.md](QUICKSTART.md) has the 10-minute version. Come back here for the full reference.

> **Disclaimer**: This is not officially supported by Ubiquiti. It uses Ubiquiti's binaries which you must download yourself from official sources. Use at your own risk. The author and contributors take no responsibility for data loss, security issues, or Ubiquiti deciding to deprecate this approach.

> **Side effects may include**: data loss, unbootable VMs, frustration, learning something, the urge to write your 
> own NVR firmware and/or software, accidentally becoming a Linux sysadmin, neighbors asking why your Mac is making 
> fan noise at 3am, Ubiquiti sending a cease-and-desist letter (this has not happened), the realization that the 
> original UNVR wasn't that bad after all, and/or the possibility of success. Consult your local sysadmin if symptoms 
> persist for more than 22 hours of uptime.  DO NOT CONSULT A SPOUSE OR PARTNER AS THEY MAY CONSIDER THIS TO BE A 
> COLOSSAL WASTE OF YOUR TIME.

## Why?

Ubiquiti markets the UNVR as capable of handling many 2K cameras, and in many deployments it does fine. In my particular deployment with a mix of cameras and active smart detection / face recognition, the UNVR was struggling — the UI was sluggish, face search took minutes, and Protect would sometimes crash. Upgrading to an ENVR would have cost significantly more than building this VM-based setup.

Your mileage may vary. If your UNVR is happy, this project isn't needed. The factors that made my setup difficult on a UNVR were:

- **Limited RAM** (4GB) on the UNVR means database working sets don't fit in cache; every search hits the disk.
- **Slow CPU** — Cortex-A53 cores are fine for video ingest but struggle with smart detection, search queries, and UI rendering simultaneously.
- **Mixed I/O on one storage pool** — the database lives on the same spinning RAID as the camera recordings AND the swap partition. Every search query competes with continuous writes from cameras *and* swap activity for the same disk heads.
- **Cannot expand**. Once you hit the capacity ceiling, your option is buying a bigger UNVR.

A Mac or Pi running a VM gives you:

- **More CPU** per dollar than UNVR replacement hardware.
- **NVMe-class storage** for the database, dramatically improving UI responsiveness.
- **Independent scaling** — add RAM, change disks, swap hosts without rebuilding from scratch.
- **Standard infrastructure** — debug, snapshot, back up, and clone the VM with standard tools.
- **Disposable host** — if the host hardware fails, recovery is "run the install scripts on a different ARM64 Mac/Pi, restore the web UI backup, reattach the recording disks." An hour or two of mostly unattended work, no replacement-NVR shopping required. The recordings live on physically movable disks; the configuration lives in web UI backups; the VM itself is just code.

## What it does

This repo provides scripts to:

1. **Build the VM** from the latest UNVR firmware. The base Debian 11 install plus a few patches makes the UNVR's Ubiquiti packages run on a virtual machine. (`install-protect-baremetal.sh`)
2. **Update the VM** in place. Query Ubiquiti's firmware API, download the latest releases of UniFi OS, Protect, Access, and AI Feature Console, install them. (`update-unifi.sh`)
3. **Manage storage**. Import existing UNVR data disks and inspect storage state. (`mount-storage.sh`)
4. **Start the VM** with stable hardware references on macOS. Identify physical disks by ATA serial and the ethernet adapter by MAC, so the VM works regardless of how macOS enumerates them this boot. (`start-protect-vm.sh`)

## Repository layout

The project is organised by *where each file runs*:

```
host/                       Runs on the macOS host
  stand-up.sh               Create a fresh VM (download ISO, disks, Debian install)
  start-protect-vm.sh       Boot the VM with stable disk/NIC references
  attach-console.sh         Attach to the VM's serial console
  snapshot.sh               Live qcow2 snapshots
  install-launchd.sh        Install the VM as a launchd daemon
  make-scripts-iso.sh       Bundle the vm/ tree into a CD-ROM ISO
  control-host-helper.sh    Host side of the virtio-serial control channel
  smartctl-host-helper.sh   Runs real SMART queries for the control channel
  protect-on-mac.conf.example   Config template (copy to protect-on-mac.conf)
  com.protect-on-mac.vm.plist   launchd plist template

vm/                         Copied into the VM and run there
  installers/               Run once, from /root, to set the VM up
    install-protect-baremetal.sh   Build the Protect stack on Debian
    install-storage.sh             Install the storage subsystem
    update-unifi.sh / uninstall.sh / mount-storage.sh
  storage/rootfs/           The storage subsystem, laid out at install paths.
                            install-storage.sh installs this tree verbatim:
    usr/bin/ustorage
    usr/local/sbin/provision-storage.sh
    usr/local/bin/ustated-shim.js
    usr/local/bin/unifi-core-storage-patch.sh
    etc/systemd/system/*.service
  wrappers/                 Control-channel guest pieces + binary interceptors
    rootfs/usr/local/bin/protect-on-mac-ctl   control channel guest client
    rootfs/usr/local/sbin/protect-installed-snapshot   one-shot checkpoint
    rootfs/etc/systemd/system/protect-installed-snapshot.service
    rootfs/usr/sbin/smartctl     SMART proxy wrapper
    rootfs/sbin/mdadm            /dev/md3 resolution fix
    smartctl-proxy.conf.example

capture/                    Diagnostic gRPC/storage capture tools
```

Host-side commands in this document are run from the `host/` directory.
The `vm/` tree is delivered into the VM as a CD-ROM ISO built by
`make-scripts-iso.sh` — see the "Fresh install workflow" section below.

## A note on UTM

UTM is a great frontend for QEMU on macOS and works fine for this project *if* you use disk image files (qcow2, raw images, etc.) for all the VM's storage — including the bulk recording storage. That's a perfectly valid setup if your DAS is formatted with an APFS or HFS+ volume and you put large qcow2 files on it.

UTM does NOT work if you want to pass through raw block devices (`/dev/disk*`). UTM's sandboxing prevents direct access to physical disks, which is what you need to attach existing UNVR disks to the VM, or to give the VM the lowest-overhead I/O path to bare DAS disks. For raw disk passthrough you have to run QEMU directly, which is what `start-protect-vm.sh` does.

In short: UTM if disk images, plain QEMU if raw disks.

## Architecture

```
+-----------------------------------------------------------+
| Host (Mac, Pi 5, ARM server, etc.)                        |
|                                                           |
|  +----------------------------------+                     |
|  | OS                               |                     |
|  |  - QEMU process                  |                     |
|  |  - Bridges VM to physical NIC    |                     |
|  +-----------------+----------------+                     |
|                    | virtio                               |
|  +-----------------v----------------+                     |
|  | VM (Debian 11 ARM64)             |                     |
|  |  - Ubiquiti UniFi OS packages    |                     |
|  |  - Protect, Access, etc.         |                     |
|  |  - Postgres: NVMe while live     |                     |
|  +----------------------------------+                     |
+-----------------------|-----------|-----------------------+
                        |           |
                  Thunderbolt    USB 3.2 Gen 2 (10Gbps)
                  /USB-C dock       |
                        |           |
              +---------v---+    +--v----------+
              | USB ethernet|    | DAS         |
              +-------------+    |  - HDD RAID |
                                 |    holds    |
                                 |  recs + DB  |
                                 +-------------+
```

The VM boots from a qcow2 file. The Protect data RAID is on spinning disks in the DAS, originally migrated from a UNVR. The Postgres database's durable home is on that array (so it travels with the recordings, UNVR-style), but while the VM runs it's served from a working copy on `vda` — the OS qcow2 on the host's NVMe — for speed, and synced back to the array at every clean shutdown. This is handled automatically by `postgres-vda.service`; there's no separate database disk to provision.

## Hardware

### My specific setup

- **Host**: MacBook Air M1, 8GB RAM, macOS 26.5
- **Dock**: 85W powered Thunderbolt dock (Amazon Basics / Good Way Technology)
- **DAS**: TerraMaster D6-320, USB 3.2 Gen 2 (10Gbps)
- **Storage disks**: 4× HDDs in RAID10 (the original UNVR disks)
- **Cameras**: A mix of UniFi cameras — 6 are HD UniFi Access cameras, others are 2K cameras at 15 FPS, 3-10 Mbps bitrate
- **NIC**: USB 2.5GbE Realtek adapter (chosen because the MBA doesn't have built-in ethernet)
- **UPS**: APC PRC3000 with AP9617 management card

### Minimum recommended

- **Host**: M-series Mac or Raspberry Pi 5 (or any ARM64 system with enough cores and RAM)
- **RAM**: 8GB works fine — that's exactly what I'm using. 16GB would be more comfortable for both the host and VM, especially if you also use the host for other tasks.
- **Storage**: USB 3.2 Gen 2 or Thunderbolt DAS with enough bays for whatever disks you plan on using. I use a TerraMaster D6-320 (6 bays, 10Gbps).
- **Disks**: Whatever HDDs you want in your RAID (4 matching disks is just what I had from the UNVR — your config can differ)
- **Solid-state for the VM's OS disk (`vda`)**: The VM's `vda` qcow2 should live on solid-state storage — your host's internal NVMe is ideal. Postgres is served from `vda` while the VM runs (see below), so this is what makes the UI snappy; there's no separate postgres disk to provision. The bulk recording RAID can be spinning disks — only `vda` benefits from being on NVMe.
- **Network**: Wired ethernet recommended but not required. WiFi can work but may not be sufficient or reliable under sustained high camera bitrates.
- **UPS**: Anything that can signal a clean shutdown when battery gets low

### Why these choices

- **ARM host** for native AArch64 execution of Debian and the UniFi binaries (which are compiled for the UNVR's ARM64 architecture).
- **USB 3.2 Gen 2 (10Gbps) DAS** because it provides plenty of headroom for both video writes and database I/O. Anything slower works at smaller scales but cuts your future options.
- **Postgres served from NVMe** because the Protect database determines how snappy the UI feels. Every face search, every timeline scroll, every smart detection query goes through postgres. On spinning storage shared with camera writes and swap, this is the #1 source of perceived slowness — so `postgres-vda` keeps the live database on the host's NVMe-backed `vda` disk while the VM runs, and writes it back to the array only at shutdown.
- **Wired networking** because high camera bitrates may overwhelm or be unreliable over WiFi. Ethernet is recommended but not strictly required.

## How it works (technical)

### The VM is a real Debian install

Not a Docker container, not a chroot. It's a full Debian 11 (Bullseye) ARM64 system with Ubiquiti's packages installed on top. The Ubiquiti packages are extracted from the latest UNVR firmware (`fwupdate.bin`), repacked as proper debs, and installed normally.

This means:
- Standard `apt-get` and `dpkg` work
- You can SSH in and debug like any other Linux system
- Updates use the same `apt` machinery as the UNVR itself
- Postgres, Nginx, Node.js — everything is Debian-native

### Hardware adaptation

The Ubiquiti software expects certain UNVR-specific hardware interfaces (storage daemons, reset buttons, optical ports, hardware watchdog). On a VM none of those exist, and the software crashes when it can't find them. The install script provides small wrappers and stubs so the software finds *something* when it looks. Nothing here bypasses authentication, licensing, or access control — the software has none of those; it just expects UNVR-shaped hardware to be present.

- **`ubnt-tools id`**: a binary that reports board ID, serial number, hardware revision. Some Protect features check this. We wrap it with a script that returns sensible defaults.
- **`/sbin/ustorage`**: the UNVR has a storage daemon (`usd`) that reports disk topology. It crashes in a VM. We provide a fake script that returns the size of `/srv` instead, and mask the real services.
- **`/sbin/mdadm`**: the real `unifi-core` runs an `mdadm --detail` check on its storage array roughly every minute. We wrap `mdadm` so this check returns success even when the storage looks different from what `unifi-core` expects. On a real UNVR the array is typically `/dev/md3`; on the VM, the array may have a different device number depending on whether you imported existing disks or let the VM create a fresh array.
- **Storage array existence**: the install script creates a small array so `unifi-core` and the storage stack have something to look at. See **Storage layout** below for what this means for multi-disk setups.

### Services we disable

The UNVR runs hardware-management services that crash on a VM:

- `usd` / `usdbd` (storage daemon and broker) — replaced by the `ustorage` fake script
- `rpsd` (reset power switch daemon) — manages the UNVR's physical reset button
- `uhwd` (hardware watchdog daemon) — UNVR-specific hardware monitoring
- `sfpd` (SFP+ optical port daemon) — for the UNVR's network ports
- `unvr-initramfs` (boot scripts that wait for UNVR-specific MTD flash) — removed entirely

These are masked (not just disabled) because they're triggered as dependencies by `ustated` and would otherwise restart.

### Storage layout

Typical device map. The actual letters depend on how QEMU enumerates devices and which storage you've configured — see notes below.

- **`/dev/vda`** (qcow2 on host disk): VM's operating system, around 32GB. Also holds the live postgres working copy (`/data/postgres-active`) that `postgres-vda` overlays onto `/srv/postgresql` while the VM runs.
- **`/dev/sd?`** (RAID from DAS or single qcow2): Mounted at `/volume1`, symlinked to `/srv`. Holds camera recordings under `/srv/unifi-protect/`, Access data under `/srv/unifi-access/`, and the postgres clusters at rest under `/srv/postgresql/` (Access and Protect).
- **`/dev/sr0`** (CD-ROM): The scripts ISO, when attached by `start-protect-vm.sh`. The VM doesn't mount this automatically — you mount it manually when you want to copy or refresh scripts. Ignored otherwise.

Storage is mounted by filesystem UUID, not device name, because device letter assignment isn't stable:

- **Order depends on how many disks you have and what order QEMU sees them.** Adding a disk shifts everyone's letters down. The `mount-storage.sh` script handles the actual mounting by UUID, so this normally doesn't matter — but it does mean you should NOT hard-code device paths anywhere.
- **Fresh install (VM creates the RAID)**: mdadm names arrays based on the VM's hostname. The first array becomes `/dev/md0`, the second `/dev/md1`. Stable across reboots.
- **Importing from another system**: When you bring disks from a real UNVR (or any other system) and let mdadm assemble them, the hostname embedded in the mdadm superblock is the *original* system's hostname. The kernel sees this as "foreign" and assigns high numbers — typically `/dev/md126` for the data array and `/dev/md127` for the original system's boot RAID. UUID-based mounting handles this transparently.

#### RAID level when the VM creates the storage from scratch

The install script's default is to create a single-disk RAID0 wrapping whatever storage you give it. This is the minimum that satisfies `unifi-core`'s expectations — it wants to see *some* mdadm-managed array — and it's a sensible default if you're attaching one large disk or a single image file.

**It is NOT what you want if you have multiple physical disks and were expecting redundancy.** If you have 2 disks and want a mirror, 3+ disks and want RAID5, or 4 disks and want RAID10, you need to create the array manually before running the install script, then point the install script at the resulting `/dev/mdN` device. Steps:

1. After Debian installs but before running `install-protect-baremetal.sh`, build your array:
   ```bash
   # RAID1 (mirror) example with two disks
   sudo mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/sdb /dev/sdc
   sudo mkfs.ext4 -L volume1 /dev/md0
   ```
2. Edit `install-protect-baremetal.sh`'s `STORAGE_DISK` variable to point at `/dev/md0` instead of a raw disk.
3. Run the install script.

The script's default is RAID0 because it's the safest no-data-loss assumption: a single disk doesn't need a parity setup, and creating a "real" RAID across multiple disks without explicit user consent risks destroying data the user wanted to keep.

#### Migrating an existing RAID from a real UNVR

If you're migrating from an existing UNVR, you don't need to create the RAID at all. Connect the disks via the DAS, and `mount-storage.sh import` will detect the existing array and mount it. The RAID level (whatever the UNVR was using — typically RAID10 for 4-bay or RAID1 for 2-bay) is preserved.

### A note on configurability

This is a Debian VM running standard Linux software. Everything in this README is the configuration that's been tested and that the scripts produce by default. None of it is mandatory:

- Don't like the RAID layout? Build whatever you want before running the install script.
- Don't want the postgres-on-`vda` working-copy behavior? Disable `postgres-vda.service` and postgres runs directly on the array (simpler, but slower on spinning disks).
- Want to add monitoring, log shipping, additional storage tiers, encrypted volumes, network policy, anything else Linux supports? Add it. It's a VM.
- Want a completely different distro? The install script is bash and dpkg-driven; porting to Ubuntu or any other Debian derivative is straightforward.

The scripts in this repo encode one working configuration that handles the UNVR-shaped corner cases. They're a starting point, not a constraint.

### Why postgres runs from vda (and how postgres-vda works)

When postgres lives on the same spinning RAID as camera recordings, every search query waits for the disks to seek away from continuous write operations. The disks never get a quiet moment to handle scattered small reads — the pattern postgres uses for face lookups, timeline queries, and smart detection event scans.

Serving postgres from solid-state storage instead:

- Took face search latency from 4 minutes to under 2 seconds
- Eliminated repeated Protect crashes during heavy use
- Eliminated "An unknown error occurred" when reassigning face matches
- Significantly improved smart detection response time
- Stopped missing image snapshots in event entries

**How it's done — `postgres-vda.service`.** Rather than carve out a dedicated postgres disk, the storage subsystem keeps the database in two places with a clear direction of trust:

- **At rest, on the array**: the real cluster directory lives at `/srv/postgresql` (`/volume1/.srv/postgresql`), alongside the recordings. Pull the disks and the database travels with them — exactly where a real UNVR's postgres expects it. No migration step to remember before moving hardware.
- **While running, on `vda`**: at boot, `postgres-vda` bind-mounts a working copy on `vda` (the OS qcow2, NVMe-backed on the host) over `/srv/postgresql`, so postgres runs at NVMe speed. At every clean shutdown it drops the bind and rsyncs the working copy back onto the array.

The direction of trust matters: `vda` is authoritative while it holds a copy; the array seeds `vda` only when `vda` is empty (a fresh VM). So an unclean power loss simply drops the bind mount (mounts aren't persistent) and the array keeps the last clean-shutdown database — one session stale at worst, never absent, never a dangling pointer.

The database working set is small — around 2.4GB in my setup — so the `vda` qcow2's normal ~32GB holds it comfortably; there's no separate sizing decision to make.

## Setup

### Prerequisites (macOS)

```bash
# Install Homebrew if you don't have it: https://brew.sh
brew install qemu wget jq smartmontools

# Make qemu launchable without password for raw disk access
sudo visudo -f /etc/sudoers.d/qemu-vm
# Add this line (replace `donnie` with your username):
#   donnie ALL=(root) NOPASSWD: /opt/homebrew/bin/qemu-system-aarch64
```

### Configuring start-protect-vm.sh

The host-side scripts read their configuration from `protect-on-mac.conf`, which lives next to the scripts. The example file `protect-on-mac.conf.example` shows every option with explanatory comments.

**Initial setup**:

```bash
cp protect-on-mac.conf.example protect-on-mac.conf
$EDITOR protect-on-mac.conf
```

Add `protect-on-mac.conf` to your `.gitignore` so your specific config doesn't end up in a public repo.

The config covers:

- **VM file paths** — qcow2, EFI variables, EFI code
- **VM resources** — CPU count, RAM (4096 MB is the UNVR baseline, more recommended)
- **Storage** — disk serial numbers for raw passthrough, or `"path|serial"` entries for qcow2 disk images. Both forms produce VM-visible serials (lsblk -o NAME,SERIAL inside the VM) so each disk has a stable, identifiable identity. Used for consistent ordering, mdadm coherence, and the optional smartctl proxy if you build it.
- **Network** — MAC address of the adapter to bridge to
- **Console** — paths for the background-mode console socket and log
- **Launchd** — labels and log paths used by the daemon installer

Override the config location for one-off testing:

```bash
PROTECT_ON_MAC_CONF=/tmp/test.conf ./start-protect-vm.sh
```

To identify your hardware values:

```bash
# Disk serials
for d in $(diskutil list -plist external physical | grep -oE 'disk[0-9]+' | sort -u); do
    echo "/dev/$d: $(smartctl -i /dev/$d 2>/dev/null | grep 'Serial Number')"
done

# Network adapter MACs
networksetup -listallhardwareports
```

### A note on macOS asking to initialize disks

macOS will prompt you to initialize any disk it doesn't recognize the filesystem of. The DAS disks have either no filesystem (fresh) or ext4/mdadm metadata (imported from UNVR), neither of which macOS recognizes. You'll see "The disk you inserted was not readable by this computer" with three buttons.

**Always click "Ignore"**. Never "Initialize" — that opens Disk Utility which would happily wipe your disks. Never "Eject" — the VM needs the disks attached.

macOS will ask about this every time the disks are connected, and again every time the VM shuts down (because the disks become idle from the host's perspective). Just click Ignore each time. There is no permanent "don't ask again" option.

### Fresh install workflow

The QEMU commands in this workflow source values from `protect-on-mac.conf` so paths and RAM stay consistent with what `start-protect-vm.sh` uses later. Make sure you've copied and edited the config (see "Configuring start-protect-vm.sh" above) before starting.

1. **Create a qcow2 disk for the VM** at the path your config specifies:
   ```bash
   source ./protect-on-mac.conf
   mkdir -p "$VM_DATA_DIR"
   qemu-img create -f qcow2 "$VM_DISK" 32G
   ```

2. **Create EFI variables storage**:
   ```bash
   dd if=/dev/zero of="$EFI_VARS" bs=1M count=64
   ```

3. **Download the Debian 11 ARM64 netinst ISO** from debian.org. Save it somewhere convenient and remember the path; we'll reference it as `$DEBIAN_ISO` below.
   ```bash
   DEBIAN_ISO="$VM_DATA_DIR/debian-11.x.0-arm64-netinst.iso"
   ```

4. **Boot the Debian installer in the VM**. This is a one-time setup; not via the regular start script. The values below come from the config:
   ```bash
   qemu-system-aarch64 \
       -machine virt,accel=hvf \
       -cpu host -smp "$VM_CPUS" -m "$VM_RAM" \
       -drive if=pflash,format=raw,unit=0,file="$EFI_CODE",readonly=on \
       -drive if=pflash,format=raw,unit=1,file="$EFI_VARS" \
       -drive if=virtio,file="$VM_DISK",format=qcow2 \
       -drive if=none,id=cd,file="$DEBIAN_ISO",format=raw,media=cdrom \
       -device virtio-scsi-pci,id=scsi0 \
       -device scsi-cd,bus=scsi0.0,drive=cd \
       -netdev user,id=net0 \
       -device virtio-net-pci,netdev=net0 \
       -nographic
   ```
   The `-netdev user` line gives the installer NAT internet access without bridging. We switch to bridged networking after install. You may need to hit `<Tab>` at the GRUB menu to add `console=ttyAMA0` to the kernel command line so the installer is visible on the serial console.

5. **Partition the VM disk during install**. Either use the whole disk or partition it manually:
   - **Whole-disk option**: Just let Debian use the entire qcow2 for `/`. Minimum 16GB usable, 32GB recommended.
   - **Partitioned option**: 2GB swap, the rest for `/`. The install script assumes a usable root with at least 16GB free, plus separate swap.

6. **Install minimal Debian** — SSH server only, no desktop environment.

7. **Bundle the VM-side scripts into an ISO** on the host. Either run `./make-scripts-iso.sh` directly, or let `start-protect-vm.sh` offer to create one when you run it later (it auto-prompts in interactive mode).

   The result lives at `$SCRIPTS_ISO` (configured in `protect-on-mac.conf`). The ISO contains the VM-side scripts plus the rest of the project (README, host-side scripts, config example) for reference.

   *Why an ISO and not `scp`?* During Debian install the VM is on QEMU's user-mode NAT, which doesn't let the host reach the VM directly. macOS also doesn't reliably hairpin-NAT for the same reason. Bridged networking works for *other* LAN hosts to reach the VM, but the Mac running QEMU often can't reach its own VM cleanly. Attaching scripts as a virtual CD-ROM sidesteps all of this — works regardless of network configuration. ISOs are also fully browsable on macOS via `hdiutil attach` or Finder, so the contents stay transparent.

8. **Boot the freshly-installed VM** with the scripts ISO attached. Same QEMU command as step 4 but replace the Debian installer ISO with the scripts ISO:
   ```bash
   qemu-system-aarch64 \
       -machine virt,accel=hvf \
       -cpu host -smp "$VM_CPUS" -m "$VM_RAM" \
       -drive if=pflash,format=raw,unit=0,file="$EFI_CODE",readonly=on \
       -drive if=pflash,format=raw,unit=1,file="$EFI_VARS" \
       -drive if=virtio,file="$VM_DISK",format=qcow2 \
       -device virtio-scsi-pci,id=scsi0 \
       -drive if=none,id=scripts,file="$SCRIPTS_ISO",format=raw,media=cdrom \
       -device scsi-cd,bus=scsi0.0,drive=scripts \
       -netdev user,id=net0 \
       -device virtio-net-pci,netdev=net0 \
       -nographic
   ```

9. **Inside the VM, mount the ISO and run `start-here.sh`**. A fresh
   Debian install has no `sudo` — log in as root and run everything bare:
   ```bash
   mkdir -p /mnt/protect-on-mac
   mount /dev/sr0 /mnt/protect-on-mac
   bash /mnt/protect-on-mac/start-here.sh
   ```
   We mount at `/mnt/protect-on-mac` rather than `/mnt` directly so we don't shadow anything Protect or related software might want to use there in the future. The ISO carries the project as a single tarball (`protect-on-mac.tgz`) — a tar preserves full filenames and execute bits, which a raw ISO 9660 filesystem does not. `start-here.sh` unpacks it to `/root/vm`, `/root/host`, `/root/capture` and then runs the installers.

10. **`start-here.sh` runs the installer** from `vm/installers/` — or you can run it yourself:
    ```bash
    cd /root/vm/installers
    ./install-protect-baremetal.sh
    ```
    `install-protect-baremetal.sh` downloads the UNVR firmware, extracts the Ubiquiti packages, adds `apt.artifacts.ui.com` as an apt repository at `/etc/apt/sources.list.d/ubiquiti.list`, and installs everything — including, as its final phase, the UNVR-faithful storage subsystem (the `vm/storage/rootfs/` tree). So one run produces a complete system. `install-storage.sh` installs that same storage layer on its own; it is kept as a standalone script for re-applying just the storage layer by hand, and a full install does not need it.

11. **Reboot the VM**, this time using `start-protect-vm.sh` from the host (which switches to bridged networking and attaches your DAS disks). The scripts ISO is no longer needed; the `vm/` tree is now in `/root/vm`.

12. **Access `https://<VM-IP>`** for initial UniFi setup. Once the VM is on bridged networking, other LAN hosts can also reach it — useful for future script updates via `scp` from a non-host machine, or just rebuild the ISO with `make-scripts-iso.sh` and re-attach.

### Refreshing scripts in the VM later

When the scripts on the host change (you pulled an update from the repo, edited something locally, etc.) and you want the VM to have the new versions:

1. Run `start-protect-vm.sh` interactively. It'll see the existing ISO and ask if you want to regenerate it. Answer yes.
2. Reboot the VM (or just attach the ISO via QMP, but reboot is simpler).
3. Inside the VM: `mount /dev/sr0 /mnt/protect-on-mac && tar --warning=no-unknown-keyword -xzf /mnt/protect-on-mac/protect-on-mac.tgz -C /root && umount /mnt/protect-on-mac`

The ISO is also fine to leave attached permanently — the VM ignores it in normal operation. You can `mount /dev/sr0` any time you want to refresh scripts from whatever the latest ISO contains.

### Migration from existing UNVR

This is the recommended workflow if you have a working UNVR you want to replace:

1. **Back up the UNVR** via the web UI. The backup can be downloaded as a local file, or stored in your Ubiquiti (UI) account's cloud backup. Cloud is the simplest path for migration — when the new VM is signed into the same UI account, the backup appears in its restore list automatically, with no file to move around.

2. **Build the test VM** following the fresh install workflow above (install script, no production data yet).

3. **Important: Do NOT remove cameras from the original UNVR's Protect**. The backup includes camera adoption state and certificates. If you remove cameras from Protect first, the backup won't bring them back automatically.

4. **Confirm the backup is reachable from the new VM, then shut down the original UNVR cleanly** via its web UI. Do not shut it down until the backup is verified available: if you used cloud backup, sign the new VM into the same UI account and check the backup shows up in its restore list; if you downloaded a local file, make sure you have it. Only once you've seen the backup is restorable on the VM should you power the UNVR down. This ordering is critical — and clean shutdown ensures the disks are in a consistent state and lets cameras gracefully drop their connection. **Keep it off the network afterwards.** If the old NVR is replacing the VM (or vice versa), it must be removed from the network — not just shut down. If it ever powers back on while still connected, it will attempt to reconnect to the cameras and fight the VM for them. Unplug it, or keep it on an isolated segment.

5. **Restore the UNVR backup onto the VM** via the VM's Protect web UI. This includes camera configurations, Access doors, users, face data, and certificates.

6. **Verify a few cameras come online** in the VM's Protect UI before proceeding. The cameras find the new controller via cached IP / cloud rediscovery, and the matching certificates from the backup let them adopt automatically.

7. **Once you're confident**, move the UNVR's disks to the DAS, connect to the host, and run `mount-storage.sh import` inside the VM. This attaches the existing video storage.

8. **If some cameras don't come back automatically**, give them a few minutes for the controller to make contact and the cameras to reconcile. If they still don't connect after that, they need to be re-adopted manually. A few things that work, roughly in order of least to most effort:

   - **Remove the device from Protect.** Once removed, the camera reappears in the device list as adoptable — adopt it again and it comes back.
   - **Use the Protect mobile app.** Under some circumstances the Protect *web UI* won't drive the re-adoption and will tell you to use the *mobile app* instead. The app can adopt cameras the web UI can't, so keep it handy for this step.
   - **Log into the device directly.** Browse to the camera's own IP and log in with username `ubnt` and the device's recovery password (shown in the UniFi UI / device settings). If the recovery password doesn't work, try the default password `ubnt`. From the device portal you can point it at the new controller.

9. **Postgres performance is automatic** — no step to run. As long as the VM's `vda` qcow2 lives on solid-state storage (host NVMe), `postgres-vda.service` already serves the database from `vda` at runtime and syncs it to the array at clean shutdown.

### Auto-starting the VM at boot

For production use, the VM should come back up automatically after a host reboot (power loss, scheduled update, etc.). This repo includes a launchd daemon that handles this on macOS.

**Install**:

```bash
brew install socat      # for console attachment, see below
./install-launchd.sh install /path/to/start-protect-vm.sh
```

This places a daemon at `/Library/LaunchDaemons/com.protect-on-mac.vm.plist`, starts the VM immediately, and configures it to:

- Start at every host boot, before any user logs in
- Restart automatically if it exits (clean shutdown, crash, OOM)
- Log script output to `/var/log/protect-vm.log`
- Log VM console output to `/var/log/protect-vm.console.log`
- Throttle restarts to one per 30 seconds, preventing runaway loops if QEMU is consistently failing

**Console access**:

The start script detects whether it's running interactively or in the background. When started by launchd (no tty), it exposes the VM's serial console as a unix socket at `/var/run/protect-vm.console.sock`. This means you can still get console access for emergency recovery — boot debugging, sysrq, login when SSH/network is broken — even though the VM is running as a daemon.

Attach with the helper script:

```bash
./attach-console.sh
```

This connects to the socket via `socat` and gives you a live, interactive console session. Press `Ctrl-O` to disconnect without affecting the VM. Only one user can be attached at a time. This is the same kind of recovery path you'd have with a USB-to-TTL adapter on the UNVR's J1 header.

When the script is run from a terminal manually (foreground use), the console behaves as before — your terminal IS the console. The socket only exists in daemon mode.

**Manage**:

```bash
./install-launchd.sh status      # Show daemon state
./install-launchd.sh start       # Start the VM
./install-launchd.sh stop        # Send SIGTERM for clean shutdown
./install-launchd.sh restart     # Stop and re-launch
./install-launchd.sh logs        # tail -f the script log
./install-launchd.sh uninstall   # Remove the daemon (logs preserved)
```

The VM doesn't auto-start until you install the daemon — by default running `start-protect-vm.sh` is a one-shot foreground process. Install the daemon when you're confident your setup is stable.

### Snapshots before risky operations

Before running an update, changing a config, or doing anything else that could break the system, take a snapshot. The qcow2 format supports copy-on-write snapshots that consume zero extra space until blocks change, and rolling back to a snapshot is also fast.

Snapshots happen **while the VM is running**. The script briefly pauses the VM via QMP (the QEMU Machine Protocol socket), snapshots each qcow2 file, then resumes. Total downtime is typically a few seconds — far better than a full shutdown/boot cycle.

```bash
# Take a live snapshot — VM keeps running, pauses briefly
./snapshot.sh create pre-os-update-5.0.20

# Or auto-named with timestamp
./snapshot.sh create-auto pre-update

# Do whatever risky thing you wanted
ssh root@<VM-IP> /root/vm/installers/update-unifi.sh --all

# If it broke, shut the VM down and roll back:
./install-launchd.sh stop          # or systemctl poweroff from inside

# Interactive rollback — lists snapshots, you pick:
./snapshot.sh rollback

# Or revert to a specific named snapshot:
./snapshot.sh restore pre-os-update-5.0.20

./install-launchd.sh start         # or ./start-protect-vm.sh
```

**`rollback` vs `restore`**: `rollback` is the interactive version — it lists every snapshot with creation dates, lets you pick one by number, and offers to clean up any newer snapshots after rolling back. `restore` is the same thing but for when you already know the snapshot name and want it scripted. Both require the VM to be shut down (see below for why).

**Why create is live but restore requires shutdown**: creating a snapshot only writes new metadata to the qcow2 file — qemu-img can do that with the VM briefly paused. Restoring rewrites the live image data to match the snapshot, which QEMU can't safely continue running on top of, so the VM has to be stopped first.

**What gets snapshotted**: the VM rootfs qcow2 (which is `vda` — so it includes the live postgres working copy) plus any extra image files listed in `STORAGE_IMAGES`. Raw disk passthrough (bulk recording disks) is NOT snapshotted — those are real block devices, often 10+ TB, where qcow2-style snapshotting isn't practical. This asymmetry is fine: an update that breaks the controller can be rolled back via the qcow2 snapshots, and the recordings on the RAID continue uninterrupted.

Other snapshot commands:

```bash
./snapshot.sh list                 # List existing snapshots
./snapshot.sh delete <name>        # Remove a snapshot (frees space)
```

Snapshots live inside the qcow2 file. Each uses no extra space initially; space is consumed as the live data diverges from the snapshot point. Old snapshots can be deleted at any time to reclaim space. If you take a snapshot and then write 50GB of changes, the snapshot effectively holds 50GB of historical data. Most snapshots stay tiny because typical post-update activity (database writes, log files) is small.

#### What a rollback actually does — and doesn't do

It's important to understand what a snapshot rollback restores and what it doesn't, because the bulk recording storage is outside the snapshot.

**Restored**:
- VM rootfs — installed package versions, configs, systemd state, service masks
- Postgres data — every cluster (main, access, protect) at the moment of the snapshot

**NOT restored**:
- Recordings on the bulk RAID — those keep accumulating regardless
- Smart detection events, face matches, and door access logs that postgres wrote between snapshot time and the rollback. Those rows are gone from the database, though the underlying recordings on the RAID are still there.

**In practice** (most upgrades): rollback is clean. Protect comes up with its old database, reconciles against the recordings on the RAID, and you're back to a working state in about 2 minutes (most of that is VM boot time). Any new recordings on the RAID stay; Protect will scan and incorporate them.

**Worst-case scenarios**:
- **Postgres schema mismatch**: if Protect or Access ran a schema migration during the failed upgrade and the rollback returns you to the old schema, you'll be on the old schema with the old binaries — which is the consistent pre-upgrade state. This is fine. The problem only appears if the upgrade was partially successful (new binaries + old schema or vice versa), but a snapshot taken BEFORE the upgrade captures the consistent pre-upgrade state, so rollback restores you to a known-good combination.
- **Gap in recordings**: if Protect was broken during the period between snapshot and rollback, some footage may not have been captured. There's nothing the snapshot can do about that — it was never written to disk.
- **Stubborn services**: occasionally postgres or unifi-protect won't start cleanly after a rollback. Usually a stale pid file (`rm /var/run/postgresql/.s.PGSQL.*` and restart) or a service mask that needs reapplying. Worst case, restore the snapshot a second time — it's idempotent.

**Newer snapshots are NOT automatically deleted after a rollback**. qcow2 keeps every snapshot as a separate metadata entry, so the snapshots you took *after* the one you rolled back to will still be listed. They hold the divergent blocks from the period you rolled back over.

The `./snapshot.sh rollback` command offers to delete them for you (recommended in most cases). The `restore` command leaves them alone — useful if you might want to fast-forward back to them, but unusual.

#### Test rollback before depending on it

Before your first real upgrade, verify the rollback actually works as expected on your specific setup:

```bash
./snapshot.sh create-auto rollback-test
ssh root@<VM-IP> "touch /root/test-rollback-marker"
./install-launchd.sh stop
./snapshot.sh restore rollback-test-<timestamp>
./install-launchd.sh start
ssh root@<VM-IP> "ls /root/test-rollback-marker"  # should fail
```

If the marker file is gone after the rollback, the rollback worked. Total time: about 5 minutes. Worth doing once before depending on the mechanism.

#### Snapshots vs disaster recovery

Snapshots live inside the qcow2 file. If the qcow2 gets corrupted, the host's NVMe dies, or the whole Mac goes up in smoke, the snapshots go with it. That sounds scary, but it's actually fine — disaster recovery with this setup is straightforward, not catastrophic:

1. **Get any working ARM64 Mac (or Pi 5, or other ARM64 host).**
2. **Run through the install workflow** — fresh Debian VM, run `install-protect-baremetal.sh`. Takes ~30 minutes.
3. **Restore the Protect and Access backups** via the web UI. This brings back cameras, doors, users, face data, certificates.
4. **Attach the recording disks from the DAS.** Run `mount-storage.sh import`. Recordings are immediately available.
5. **Optionally restore postgres** from a pg_dump if you took one. Most of what postgres holds (faces, events, etc.) comes back via the web UI backup restore, so this is usually not needed.

Total recovery time: an hour or two of mostly-unattended work. The bulk recording data lives on disks you can physically move; the configuration lives in web UI backup files you can store anywhere; the VM itself is recreatable from these scripts.

The two things you should back up off-host on a schedule:

- **Protect and Access backups** from the web UI (download them periodically, store on a NAS / cloud)
- **Optionally pg_dump output** if you want the option to roll back postgres independently of the snapshot mechanism

The recordings on the RAID don't need a separate backup — they're already on a RAID and the disks are physically movable. The host hardware is the only thing that's truly disposable here.

## Updates

Once running, updates are handled by `update-unifi.sh`:

```bash
./update-unifi.sh              # Show what's available
./update-unifi.sh --check      # Same as default
./update-unifi.sh --sync-os    # Update UniFi OS packages from latest UNVR firmware
./update-unifi.sh --protect    # Update Protect to latest stable
./update-unifi.sh --access     # Update Access to latest stable
./update-unifi.sh --all        # Sync OS + upgrade Protect + Access
./update-unifi.sh --all-edge   # Same but use beta channels
```

The script queries Ubiquiti's firmware API (the same one the UNVR uses to find updates) and downloads the latest debs directly. Checksum verification on every download.

### Should I run `apt-get upgrade`?

**Short answer**: yes, it's safe. The install script holds all the Ubiquiti packages, so `apt-get upgrade` will skip them and only upgrade Debian-side packages (kernel, openssl, libraries, etc.).

When you run `apt-get upgrade` you'll see a message like:

```
The following packages have been kept back:
  ds  unifi-access  unifi-core  unifi-protect  ulp-go  ...
```

That's intentional and correct — those packages are managed by `update-unifi.sh`, not by apt. Held packages get skipped during `apt-get upgrade` so a routine system update can't break your Protect install.

**What's safe to upgrade via apt**:

- Debian base system packages (kernel, openssl, glibc, etc.) — security and bugfix updates
- PostgreSQL minor versions (14.x → 14.y) — postgres handles these in place
- Build tools, libraries, supporting utilities

**What you should NOT do**:

- **Don't `apt-mark unhold` the Ubiquiti packages unless you know what you're doing.** Use `update-unifi.sh` instead — it coordinates the version handling and unholds/re-holds the packages around its operations.
- **Avoid `apt-get dist-upgrade`** unless you understand exactly what it's doing. Unlike plain `upgrade`, `dist-upgrade` can install new packages and remove existing ones to satisfy dependencies. This could reintroduce `unvr-initramfs` (which we deliberately removed because it breaks VM boot) or install other UNVR-only packages.
- **PostgreSQL major versions (14 → 15)** would require a full migration with `pg_upgradecluster`. Not normally pushed by Debian stable, but worth being aware of as bullseye approaches end-of-life.

**Service masks survive upgrades**. The `usd`, `usdbd`, `rpsd`, `uhwd`, `sfp`/`sfpd` masks installed during setup are at the systemd level, not the package level. Package upgrades won't undo them. New services introduced by a UniFi OS update might need to be masked too — `update-unifi.sh --sync-os` handles the known ones automatically.

**Unattended upgrades**: if you want automatic security patches, install `unattended-upgrades` and configure it for security-only updates. Since the Ubiquiti packages are already held, unattended-upgrades will leave them alone automatically.

## The host↔guest control channel

A couple of features need the VM to ask the *host* to do something — take a qcow2 snapshot, or run a real SMART query against a USB disk the VM itself can't see. The VM and host talk over a dedicated **virtio-serial control channel**.

Why not just SSH from the VM to the host? Because the VM's only network is the bridged LAN, and a host usually can't reach its own bridged VM cleanly (the switch won't hairpin a frame back out the port it came in on). A virtio-serial port sidesteps that entirely:

- **No network.** It's a serial port, not a NIC — no IP at all, so it can't collide with any LAN subnet and bridged-networking flakiness is irrelevant.
- **Invisible to UniFi OS.** It's a character device, not a NIC or disk — the Ubiquiti software never sees it.
- **Locked down by design.** The host side (`control-host-helper.sh`) is not a shell and never `eval`s anything. It's a dispatcher with a fixed verb vocabulary — `ping`, `snapshot`, `smartctl`. A request for anything else has no code path; every argument is validated against a strict character set. This is the same guarantee an SSH forced command gives, achieved structurally.

`start-protect-vm.sh` starts the listener automatically (it owns the socket, unprivileged; QEMU connects as a client). The guest side is `/usr/local/bin/protect-on-mac-ctl`. If the channel is present it's used; if not, callers fall back gracefully.

What rides it today:

- **Snapshots** — automatic checkpoints bracket the install: `install-protect-baremetal.sh` takes a `fresh-debian` snapshot before it installs anything (Phase 0), and a one-shot systemd unit takes a `protect-installed` snapshot the first time Protect comes up healthy, then disables itself. `update-unifi.sh` takes a `pre-update-<timestamp>` snapshot before every update. And any script in the VM can run `protect-on-mac-ctl snapshot <label>` to checkpoint the VM disks from inside the guest. The `snapshot` verb is idempotent — re-requesting an existing named checkpoint leaves it as-is.
- **The smartctl proxy** — see the next section.

**Host requirements** — `stand-up.sh` sets all of this up for you (it installs `socat` and offers to add the sudoers rule). The following is for a host configured by hand, or an existing VM:

- `socat` — carries the channel: `brew install socat`.
- For the `snapshot` verb, the listener runs `snapshot.sh` via `sudo -n` (it needs root for the QMP socket and `qemu-img`). Add a NOPASSWD sudoers rule:
  ```bash
  sudo visudo -f /etc/sudoers.d/protect-on-mac
  # Add (replace `donnie` with your username, and the path with yours):
  #   donnie ALL=(root) NOPASSWD: /Users/donnie/.../host/snapshot.sh
  ```
  Without it, snapshot requests fail and callers fall back (e.g. `update-unifi.sh` warns and continues). The `smartctl` verb needs no rule here — `smartctl-host-helper.sh` has its own (see the smartctl proxy section).

## Optional: smartctl proxy (real disk health in Protect)

By default the installer drops a fake `/usr/sbin/smartctl` into the VM that always reports a healthy virtual disk. That keeps Protect happy, but it means Protect's UI can never warn you about a disk that's actually dying — bad sectors, climbing reallocated-sector counts, SMART failures. The data lives on USB-attached disks on the Mac; the VM only ever sees virtio-scsi devices with no real SMART data.

The smartctl proxy bridges that gap. The fake `smartctl` is replaced with a wrapper that forwards SMART queries back to the Mac, which *can* read the physical disks over USB. Protect then shows genuine per-disk health.

This is **optional and opt-in**. If you don't set it up, nothing changes — the fake `smartctl` is used and the VM behaves exactly as before.

### How it works

1. Protect runs `smartctl <flags> /dev/sdX` inside the VM.
2. The VM-side wrapper resolves `/dev/sdX` to its disk serial (via `lsblk`).
3. It sends `smartctl <serial> <flags>` over the [control channel](#the-hostguest-control-channel).
4. The host helper validates the input, looks the serial up in a serial-to-device map (`disk-serial.map`, rewritten by `start-protect-vm.sh` on every VM start — macOS renumbers `/dev/diskN` constantly), and runs the real `smartctl` against the matching `/dev/diskN`.
5. The output travels back and the wrapper hands it to Protect.

If anything fails — proxy disabled, control channel unavailable, unknown disk — the wrapper falls through to the local real `smartctl`. The proxy is strictly best-effort; it can't break the VM.

Only **raw-passthrough disks** (`DISK_SERIALS` in `protect-on-mac.conf`) are proxied. qcow2 disk images have no underlying physical disk, so they keep returning local data.

### Prerequisite: SAT SMART pass-through on the Mac

macOS does **not** expose ATA/SMART pass-through for USB-attached disks natively. You need the kasbert `OS-X-SAT-SMART-Driver` kext. The easiest source is the **signed** `SATSMARTDriver` package from [binaryfruit.com](https://binaryfruit.com) — the vendor of [DriveDx](https://binaryfruit.com/drivedx), a well-known commercial Mac disk-health app, so it's a recognized source rather than a random download. `stand-up.sh` offers to fetch that package for you and extracts it under `$VM_DATA_DIR/SATSMARTDriver/`; installing DriveDx itself also bundles and installs the kext. Either way, on Apple Silicon loading a third-party kext requires **Reduced Security** mode (set in the recoveryOS Startup Security Utility) — `stand-up.sh` can't do that step for you. See "Limitations and known issues" below — this is a real dependency, not a footnote.

**If the binaryfruit download ever disappears:** the same driver can be built from source — [`github.com/kasbert/OS-X-SAT-SMART-Driver`](https://github.com/kasbert/OS-X-SAT-SMART-Driver) — which needs the Xcode command-line tools (`xcode-select --install`). A self-built kext is **unsigned**, and an unsigned kext is *harder* to load on Apple Silicon than the signed binaryfruit build (more Reduced Security friction, and newer macOS resists unsigned kexts further). Prefer the signed download while it exists; treat the source build as a last resort.

Verify pass-through works for your enclosure before bothering with the rest. With the kext loaded:

```bash
# Confirm the enclosure's bridge supports SAT pass-through
ioreg -r -w 0 -c fi_dungeon_driver_IOSATDriver \
  | egrep 'Enclosure|PassThroughMode|Capable|KnownEnclosure'

# And that smartctl actually reads the disk
brew install smartmontools
sudo smartctl -a /dev/diskN
```

If `SATSMARTCapable = Yes` shows up and `smartctl -a` returns real attributes, you're good. If not, the proxy has nothing to forward and there's no point setting it up.

### Setup

Because the proxy rides the [control channel](#the-hostguest-control-channel), there is **no SSH key, no `PROXY_HOST`, no Remote Login, and no `authorized_keys` entry** to manage. Three steps:

**1. Install the VM with the proxy enabled.** Run the bare-metal installer with `SMARTCTL_PROXY=1`:

```bash
cd /root/vm/installers
SMARTCTL_PROXY=1 bash install-protect-baremetal.sh
```

This installs real `smartmontools` (the real binary kept as `/usr/sbin/smartctl.real`), the proxy wrapper at `/usr/sbin/smartctl`, and the control-channel client `/usr/local/bin/protect-on-mac-ctl`. (Already installed without the proxy? Re-run the installer with the flag.)

**2. On the Mac — install smartmontools and socat:**

```bash
brew install smartmontools socat
```

If you ran `stand-up.sh` and answered yes to the smartctl-proxy prompt, `smartmontools` is already installed and the SAT SMART kext installer already downloaded — this step is just for hand-configured hosts. `socat` carries the control channel; `smartmontools` is the real `smartctl` the host helper runs. `smartctl-host-helper.sh` is invoked in place from the `host/` directory by `control-host-helper.sh` — nothing to copy. Its `DISK_MAP` path must match `DISK_MAP` in `protect-on-mac.conf`; both default to `$VM_DATA_DIR/disk-serial.map`, so unless you changed `VM_DATA_DIR` there's nothing to do.

No sudoers rule is needed for the proxy — on macOS `smartctl` reads SMART through IOKit, which works unprivileged, so `smartctl-host-helper.sh` runs it directly.

That's the whole setup. Restart the VM with `start-protect-vm.sh` so the control channel is attached and the disk map is regenerated.

### Verify

From inside the VM:

```bash
protect-on-mac-ctl ping            # should print: pong
smartctl -a /dev/sda               # a raw-passthrough disk
```

If the channel is up, `ping` returns `pong`. If the proxy is working, `smartctl -a` shows the real disk's model, serial, temperature, and SMART attributes — not the fake "Virtual Storage Device". A failing disk shows `SMART overall-health self-assessment test result: FAILED`. For that health to surface in Protect's *Storage Manager panel*, see [Storage health and the Storage Manager panel](#storage-health-and-the-storage-manager-panel) below.

The control-channel listener writes diagnostics to its stderr (the terminal running `start-protect-vm.sh`, or `LAUNCHD_ERROR_LOG` in background mode), and `start-protect-vm.sh` prints the disk-map path and count on every start.

### Caveats

- **Per-disk only.** RAID devices (`/dev/md3`) have no single serial, so a `smartctl` call against the array falls back to local data. Protect mostly queries individual disks, which is what gets proxied.
- **The map is only as fresh as the last VM start.** If you hot-swap a disk while the VM is running, the map is stale until the next `start-protect-vm.sh`. The wrapper falls back gracefully in the meantime.
- **State-changing flags are refused.** The host helper only ever runs read-only SMART queries — it rejects self-test triggers (`-t`), `--set`, and SMART enable/disable. Protect doesn't need those.

## Storage health and the Storage Manager panel

The smartctl proxy is one piece of a larger goal: **getting real disk health — and disk-failure alerts — into Protect on a VM, and making the Storage Manager panel render.** With the storage shim described below, that goal is met.

### The goal

On a real UNVR, the Storage panel lists every disk with its health, and a failing disk turns the panel red ("Drive Failure Detected") and raises an alert. The aim here is the same on the VM: a dying disk in the DAS should be *noticed*, not silently ignored behind a faked-healthy virtual disk.

### What works

- **`smartctl` returns real data** — with the optional [smartctl proxy](#optional-smartctl-proxy-real-disk-health-in-protect), any `smartctl` call in the VM is forwarded to the Mac and answered with genuine SMART data for the real USB-attached disks.
- **`ustorage` returns real data** — `ustorage-vm.py` replaces the installer's static fake `/usr/bin/ustorage` with a dynamic one that reports real per-disk health, array state, and all three space types (primary, swap, root). Failure detection covers both SMART self-assessment *and* md-array member state — a dropped disk shows as `faulty`.
- **`mdadm --detail /dev/md3` works on migrated arrays** — `mdadm-vm-wrapper.sh` redirects that hardcoded call (UniFi software always asks for `/dev/md3`) to whatever device the imported array actually assembled as (`/dev/md12x` on a migration).
- **`unifi-core`'s background storage health poll runs on real data** — with the smartctl proxy in place, the every-60-seconds storage check succeeds with genuine SMART instead of failing.
- **The Storage Manager panel renders** — with the storage shim below installed, Settings → System → Storage shows the array, every disk with model / serial / temperature / health, and capacity. A failing disk surfaces the same red state a real UNVR shows.

### Why the panel needs a shim

The panel is driven by `unifi-core`'s live `nvr.systemInfo.ustorage` object. On a real UNVR that data flows:

```
usd  (storage daemon, :10055)
  -> ustated  (UI State Exporter — translates events to a storage gRPC API)
  -> unifi-core  (subscribes on 127.0.0.1:11052; renders the panel)
```

`usd` cannot run on this VM — it is built for the UNVR's read-only-squashfs + overlay-root boot layout and crashes resolving the root volume on a normal Debian install. With `usd` dead, `ustated` has nothing to translate, `unifi-core`'s storage object stays empty, and the panel spins forever.

The fix bypasses both `usd` and `ustated`:

- **`ustated-shim.js`** — a small Node gRPC server that serves `unifi.firmware.storage.v1.StorageAPI` (the exact API `unifi-core` subscribes to) directly on `127.0.0.1:11052`, built from `unifi-core`'s own generated protobuf modules. It sources live data from `/sys`, `/proc`, and `smartctl`, and supplies the array level, spaces, and storage settings.
- **`unifi-core-storage-patch.sh`** — `unifi-core`'s bundled `service.js` hardcodes the disk list of its `ustorage` object to empty and only ever calls `ustorage space inspect`. The patch makes its `system.ustorage.inspect` handler also call `ustorage disk inspect` (served by `ustorage-vm.py`), so the per-disk list populates. `service.js` is a vendor bundle that updates overwrite, so the patch is re-applied on every boot by a systemd unit.

### Setup

This is **optional and opt-in**, like the smartctl proxy. Without it the panel spins; the rest of the VM is unaffected. It works best alongside the smartctl proxy — without the proxy the disks render with faked-healthy SMART data; with it they show genuine health.

Inside the VM, as root:

```bash
# 1. The shim — serves the storage gRPC API on :11052
install -m 0755 ustated-shim.js      /usr/local/bin/ustated-shim.js
install -m 0644 ustated-shim.service /etc/systemd/system/ustated-shim.service
systemctl mask ustated          # frees :11052 permanently
systemctl daemon-reload
systemctl enable --now ustated-shim.service

# 2. The service.js patch guard — re-applies the disk-list patch each boot
install -m 0755 unifi-core-storage-patch.sh      /usr/local/bin/unifi-core-storage-patch.sh
install -m 0644 unifi-core-storage-patch.service /etc/systemd/system/unifi-core-storage-patch.service
systemctl enable unifi-core-storage-patch.service
/usr/local/bin/unifi-core-storage-patch.sh       # apply once now
systemctl restart unifi-core
```

`ustated-shim.js` requires `node24` (already present in the VM as `/usr/bin/node24`) and `unifi-core`'s `node_modules` (present on any install). The patch guard is idempotent, never fails the boot, and saves the original `service.js` as `service.js.prepatch`.

### Caveat: firmware updates

The `service.js` patch targets one specific line in a minified vendor bundle. A `unifi-core` update overwrites `service.js`; the patch guard re-applies it on the next boot or `unifi-core` restart. But if an update *restructures* that handler, the anchor string won't match — the guard logs `expected exactly 1 anchor, found 0 — NOT patching` and no-ops, leaving the panel's disk list empty until the patch is updated. Check `journalctl -u unifi-core-storage-patch` after any `unifi-core` update. `ustated-shim.js` is unaffected by `unifi-core` updates.

## Migrating back to a real UNVR (or ENVR, or other host)

If you decide to go back to a real UNVR, upgrade to an ENVR, or move to a different VM host, the reverse-migration workflow is close to the forward one — backup-first, restore on the new system, then move the disks for the recording history.

**Workflow**:

1. **Back up Protect and Access** via the VM's web UI. Download both backup files (Protect and Access have separate backups).
2. **No database-migration step is needed.** `postgres-vda` syncs postgres onto the array (`/srv/postgresql`) at every clean shutdown, so the clean `systemctl poweroff` in the next step already leaves the disks with a complete UNVR-style layout. (`uninstall.sh status` shows export readiness and the checklist.)
3. **Cleanly shut down the VM**: `systemctl poweroff`
4. **Remove the disks** from the DAS.
5. **Install the disks** in the target hardware (real UNVR, ENVR, etc.).
6. **Power on the target hardware**. It should boot to its initial setup state, or come up with what's on the disks depending on the target's behavior.
7. **Restore the Protect and Access backups** via the target's web UI, the same way you'd restore on any new UniFi controller. This brings camera configurations, doors, users, face data, and certificates over.
8. **Cameras automatically re-adopt** to the new controller within a few minutes, using the cached identity from the restored backup.

This mirrors the forward migration: backup-first carries the configuration, the disks carry the recording history, and the restore on the target stitches them back together. The cameras don't care which hardware their controller runs on as long as the certificates match.

**Helper commands**:

```bash
./uninstall.sh status      # Show export readiness and the checklist
```

No guarantees this works perfectly — hardware differences, firmware versions, and the target's consistency checks may still cause issues. Always keep the backup files until you've verified everything works on the new hardware.

The `uninstall.sh` script does NOT uninstall the Ubiquiti software from the VM, delete recordings, or touch the launchd daemon. The VM stays usable; you've just prepped the data for export. To remove the launchd daemon on the host:

```bash
./install-launchd.sh uninstall
```

## Compatibility with UniFi accessories

The VM is fully compatible with:

- **UniFi Access** hubs and door controllers (UA-G2-PRO, UAH, etc.)
- **AI-Port** — lets you add ONVIF cameras to Protect and adds smart detection types (people, vehicles, packages, etc.) to cameras that don't natively support those features
- **AI-Key** — adds additional AI capabilities beyond what AI-Port provides, such as natural language search, speech-to-text, and additional smart detection types
- **SuperLink** — for UniFi IoT sensors and devices
- **UniFi Access cameras** with door integration

In my deployment, all of these were working on the UNVR and continue to work on the VM after migration. Adoption, configuration, and firmware updates work as expected.

## Performance

In my setup (28 mixed cameras: 6 HD Access cameras, 22 2K cameras at 15 FPS / 3-10 Mbps bitrate), on an 8GB MacBook Air M-series:

- **CPU**: VM 4 vCPUs around 30-70% usage, idle around 30% on the host
- **RAM**: VM uses 4-5GB, host swaps lightly
- **I/O wait**: 5-15% on the VM (compared to 40-60% on the UNVR in the same workload)
- **Disk write**: ~20-30 MB/s sustained to the RAID
- **Face search**: under 2 seconds (was 4+ minutes on the UNVR with the same data)
- **Timeline scrub**: near-instant compared to the overloaded UNVR
- **Remote access**: `unifi.ui.com` cloud access works seamlessly. Live streaming and config changes via cloud worked from day one with no issues.

A 16GB host would give substantial headroom for more cameras and heavier smart detection workloads.

## Limitations and known issues

- **Firmware updates can break things**: a UniFi OS update can introduce new services or change package contents. Test in a separate VM first if possible. The masked-services list may need to grow.
- **Cameras may need re-adoption** in some cases. The backup-restore approach handles most of this automatically, but if a camera was briefly adopted by another controller during testing, it may need manual re-adoption.
- **Initial setup is hands-on**. The Debian install step isn't automated. Once Debian is installed, the rest is scripted.
- **Real disk health needs a kext**. By default Protect sees a faked-healthy virtual disk. The optional [smartctl proxy](#optional-smartctl-proxy-real-disk-health-in-protect) surfaces genuine SMART data, but macOS has no native ATA pass-through for USB disks — it depends on the kasbert `OS-X-SAT-SMART-Driver` kext (bundled with DriveDx), and loading a third-party kext on Apple Silicon requires booting once into recoveryOS to enable **Reduced Security** mode. If you don't set up the proxy, none of this applies.
- **The Storage Manager panel needs the storage shim**. Out of the box the UniFi OS Storage panel sits on a loading spinner — it depends on the `usd` daemon, which can't run on a VM. The optional [storage shim](#storage-health-and-the-storage-manager-panel) (`ustated-shim.js` plus a small `service.js` patch) makes the panel render with real disk health. The patch targets a minified vendor bundle and may need re-checking after `unifi-core` updates.

## Recovery from common failures

A handful of failure modes are well understood and have one-line fixes. Knowing the symptoms saves time when something goes wrong.

### Host disk pressure (macOS, APFS snapshots)

macOS APFS takes local Time Machine snapshots automatically — every hour, even without a backup drive attached. They silently pin space that Disk Utility happily reports as "free" (it counts purgeable space). The first sign is usually a VM operation failing with ENOSPC or the qcow2 storage images mysteriously refusing to grow, even though the GUI says you have plenty of room.

Check the truth:

```
df -h /                          # what the kernel actually sees
tmutil listlocalsnapshots /      # what Time Machine is holding onto
```

If `df` is much smaller than the GUI claims, thin the snapshots:

```
sudo tmutil thinlocalsnapshots / 200000000000 4
df -h /                          # confirm recovery
```

That asks macOS to free up to ~200 GB at urgency 4 (max) and lets APFS coordinate the deletes — more reliable than iterating `tmutil deletelocalsnapshots`, which can hit stale-handle errors (`POSIXError Code=70`) when macOS is auto-purging in parallel. macOS keeps the most recent snapshot for short-term undo; that's normal and worth leaving alone.

A reboot can also help: it lets APFS finish background pruning that was queued behind locked snapshot references. If `df` still looks tight afterward, hunt for the actual hog with:

```
sudo du -sh ~/Library/Containers/* 2>/dev/null | sort -h | tail
```

UTM, Docker, Messages, and Mail are the usual offenders.

### Stale `postmaster.pid` after ungraceful VM shutdown

If the QEMU process is killed (host reboot, `kill -9`, power loss) without giving the guest a clean shutdown, `postgres@14-protect`'s lockfile survives into the next boot. `unifi-protect`'s pre-start sees the cluster as "running" but unreachable, and Protect refuses to start.

**Symptoms**:

- `systemctl status unifi-protect` shows `Failed to connect to service 'postgres'` / `connect ENOENT /var/run/postgresql/.s.PGSQL.5433`.
- `journalctl -u postgresql@14-protect` shows `Error: pid file is invalid, please manually kill the stale server process.`
- `pg_lsclusters` shows the protect cluster as `down`.

**Fix** (inside the VM as root):

```
rm -f /srv/postgresql/14/protect/data/postmaster.pid
systemctl start postgresql@14-protect
pg_lsclusters                    # confirm: status 'online'
systemctl start unifi-protect
```

**Prevention**: prefer `systemctl poweroff` inside the VM, or send `system_powerdown` via the QMP socket. Both give postgres a chance to release the lockfile before QEMU exits.

The `postgresql@14-protect.service` unit ships with a `clean-postmaster-pid.conf` drop-in that is supposed to clean a stale pid before start, but the migrate-script's direct `pg_ctlcluster stop` call bypasses the systemd ExecStartPre chain in this case. Manual `rm` is the reliable recovery.

### First-boot DB-cluster migration runs on every fresh install

On a real UNVR, the storage array is present at first Protect start, so the DB initializes directly on `/srv/`. In this VM, the array is user-driven through the web UI — meaning the first Protect start happens *before* `/srv/` is real, the DB initializes on `/data/`, and only on the next start (after the array exists) does the cluster migrate to `/srv/`.

This migrate path is normal. You'll see this in the journal:

```
pre-start: PostgreSQL running with /data/ but /srv/ has the real DB, running migrate script
```

The migrate script (`/usr/bin/unifi-protect-db-cluster-migrate`) rsyncs the cluster directory, updates `data_directory` in the postgres config, and triggers a restart through systemd. It runs exactly once per cluster and writes `/srv/.db-cluster-migrated.ctl` when done.

If it fails mid-way (most commonly because of the stale `postmaster.pid` trap above), the recovery is the same: clear the pid, start the cluster manually, then start `unifi-protect`. Leftover bytes in `/data/postgres-active/` and `/data/postgresql/14/protect/` after a successful migrate are harmless and can be cleaned up later.

### Storage pane transient render race

Right after Protect starts, the Storage Manager pane sometimes shows three disks as `UniFi Protect VM Disk` and one as `QEMU HARDDISK`. This is a race during first disk-model discovery: `unifi-core` queries one disk before the smartctl shim has answered for it, and caches the kernel's raw response. A single reload of the storage pane refreshes through the warmed-up shim and all four disks show consistently.

If a disk stays as `QEMU HARDDISK` across multiple reloads, the smartctl shim isn't intercepting that disk:

```
systemctl status ustated-shim
journalctl -u ustated-shim
```

Worth noting: the kernel-level identity (`lsblk -o NAME,MODEL,SERIAL`) always says `QEMU_HARDDISK` for qcow2-backed disks regardless of the shim. The shim only rewrites the smartctl layer. That's intentional defense — anything that bypasses smartctl will see the QEMU identity and behave accordingly. If you pass real disks through to the VM, their real model strings (e.g. HGST) pass through unchanged because the shim's matching is keyed on the QEMU vendor string.

### Generic fallback — what to check first

For anything not covered here, attach the serial console (`./host/attach-console.sh`) and inspect:

```
systemctl --failed               # any unit not happy
journalctl -p err -b              # errors since this boot
df -h                             # disk space inside the VM
pg_lsclusters                     # postgres clusters
cat /proc/mdstat                  # RAID state
```

That's usually enough to tell whether a service is wedged, a disk is failing, the array is degraded, or you're out of space — the four most common root causes.

## Possible future enhancements

- **Fully automated VM creation**: A script that creates the qcow2, boots the Debian installer with a preseed file, runs the install script, and produces a ready-to-go VM image. Doable, just not done yet.

## Files

See "Repository layout" near the top for the directory tree. The detail:

### `host/` — live on the Mac

- **`stand-up.sh`** — create a fresh VM: download + verify the Debian netinst ISO, create the OS disk / UEFI varstore / blank data disks, run the Debian installer.
- **`start-protect-vm.sh`** — start the VM with stable hardware references. Sources the config.
- **`attach-console.sh`** — attach to the VM's serial console for emergency access when running as a daemon.
- **`snapshot.sh`** — create/restore/list/delete qcow2 snapshots before risky operations.
- **`install-launchd.sh`** — install/manage the launchd daemon that auto-starts the VM at boot.
- **`make-scripts-iso.sh`** — bundle the `vm/` tree into an ISO for initial bootstrap (when scp from host can't reach the VM).
- **`control-host-helper.sh`** — host side of the virtio-serial control channel. A locked-down dispatcher (`ping`/`snapshot`/`smartctl`); `start-protect-vm.sh` launches it. See "The host↔guest control channel".
- **`smartctl-host-helper.sh`** — runs real disk SMART queries for the `smartctl` verb of the control channel. See the "smartctl proxy" section.
- **`protect-on-mac.conf.example`** — configuration template. Copy to `protect-on-mac.conf` and edit.
- **`com.protect-on-mac.vm.plist`** — launchd configuration template used by `install-launchd.sh`.

### `vm/installers/` — run once inside the VM, from `/root`

- **`install-protect-baremetal.sh`** — full UniFi software install. Run once during initial setup.
- **`install-storage.sh`** — install the storage subsystem: walks `vm/storage/rootfs/` and installs every file at its mirrored path, then wires up the systemd units. See "Storage health".
- **`update-unifi.sh`** — query API, download, install latest UniFi packages.
- **`mount-storage.sh`** — import an existing UNVR RAID and show storage status.
- **`uninstall.sh`** — show reverse-migration export readiness and the checklist for moving to other hardware.

### `vm/storage/rootfs/` — the storage subsystem, laid out at install paths

`install-storage.sh` installs this tree verbatim. See "Storage health".

- **`usr/bin/ustorage`** — dynamic `ustorage` replacement: reports real per-disk and array health instead of the installer's static fake.
- **`usr/local/sbin/provision-storage.sh`** — boot-time disk provisioner + `space nuke` teardown/reprovision worker.
- **`usr/local/bin/ustated-shim.js`** — storage-API gRPC shim. Serves `unifi.firmware.storage.v1` on `127.0.0.1:11052` so the Storage Manager panel renders.
- **`usr/local/bin/unifi-core-storage-patch.sh`** — idempotent re-apply guard for the `unifi-core` `service.js` disk-list patch.
- **`etc/systemd/system/provision-storage.service`** — runs the provisioner at boot, before `ustated-shim` and `unifi-core`.
- **`etc/systemd/system/ustated-shim.service`** — runs `ustated-shim.js` at boot.
- **`etc/systemd/system/unifi-core-storage-patch.service`** — runs the patch guard before `unifi-core` starts.
- **`etc/systemd/system/storage-nuke.service`** — on-demand teardown worker, triggered by `ustorage space nuke` (not enabled at boot).

### `vm/wrappers/` — control-channel client and binary interceptors

- **`rootfs/usr/local/bin/protect-on-mac-ctl`** — guest client for the host↔guest control channel. Installed by `install-protect-baremetal.sh`; used for snapshot triggers and by the smartctl wrapper.
- **`rootfs/usr/local/sbin/protect-installed-snapshot`** + **`rootfs/etc/systemd/system/protect-installed-snapshot.service`** — a one-shot that takes a `protect-installed` snapshot the first time Protect is healthy, then disables itself. Installed + enabled by `install-protect-baremetal.sh`.
- **`rootfs/usr/sbin/smartctl`** — VM side of the optional smartctl proxy. Installs as `/usr/sbin/smartctl`; forwards SMART queries to the host over the control channel. See the "smartctl proxy" section.
- **`rootfs/sbin/mdadm`** — redirects `mdadm --detail /dev/md3` to the real array on migrated setups. See "Storage health".
- **`smartctl-proxy.conf.example`** — optional config (a kill switch) for the proxy wrapper. Copy to `/etc/default/smartctl-proxy` in the VM.

### `capture/` — diagnostics

- **`capture-storage-flow.sh`** / **`capture-disk-event.sh`** — capture the gRPC/storage daemon traffic used to reverse-engineer the storage wire protocol.

## Credits

This work is built on:

- [dciancu/unifi-protect-unvr-docker-arm64](https://github.com/dciancu/unifi-protect-unvr-docker-arm64) — the Docker-based approach that proved Ubiquiti's binaries could run on non-UNVR hardware. The package extraction and hardware spoofing patterns originated there.
- Ubiquiti's UNVR firmware and packages. These are not redistributed by this project — the install and update scripts (run by you) download them directly from Ubiquiti's official servers (`fw-download.ubnt.com` for firmware, `apt.artifacts.ui.com` for packages). The scripts add Ubiquiti's apt repo to `/etc/apt/sources.list.d/ubiquiti.list` so future package updates pull from official sources.
- Vibe-coded with [Claude](https://claude.ai), which dramatically reduced the time from idea to working solution and produced the extensive inline documentation throughout.

## License

Scripts in this repository are MIT licensed. Ubiquiti software is owned by Ubiquiti Inc. and subject to their license — downloading and using it is your responsibility.
