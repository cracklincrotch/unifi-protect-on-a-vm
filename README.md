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
2. **Update the VM** in place. Query Ubiquiti's firmware API, download the latest releases of UniFi OS, Protect, Access, and AI Feature Console, install them. (`unifi-update.sh`)
3. **Manage storage**. Import existing UNVR data disks, migrate the database to a dedicated SSD. (`mount-storage.sh`)
4. **Start the VM** with stable hardware references on macOS. Identify physical disks by ATA serial and the ethernet adapter by MAC, so the VM works regardless of how macOS enumerates them this boot. (`start-protect-vm.sh`)

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
|                    | virtio                                |
|  +-----------------v----------------+                     |
|  | VM (Debian 11 ARM64)             |                     |
|  |  - Ubiquiti UniFi OS packages    |                     |
|  |  - Protect, Access, etc.         |                     |
|  |  - Postgres on dedicated SSD     |                     |
|  +----------------------------------+                     |
+-----------------------|-----------|-----------------------+
                        |           |
                  Thunderbolt    USB 3.2 Gen 2 (10Gbps)
                  /USB-C dock        |
                        |           |
              +---------v---+    +--v----------+
              | USB ethernet|    | DAS         |
              +-------------+    |  - SSD: DB  |
                                 |  - HDDs:    |
                                 |    RAID     |
                                 +-------------+
```

The VM boots from a qcow2 file. The Protect data RAID is on spinning disks in the DAS, originally migrated from a UNVR. The Postgres database lives on a separate SSD (highly recommended) — could be a qcow2 on internal NVMe, or a real SSD in the DAS.

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
- **SSD for postgres**: Strongly recommended on some kind of solid-state storage. Could be a qcow2 on your host's internal NVMe (works great if you have space), or a dedicated SSD in the DAS (slower in theory, but lets you move the whole stack by moving the DAS). I haven't directly benchmarked DAS SSD vs internal NVMe — the internal NVMe is what I'm currently using.
- **Network**: Wired ethernet recommended but not required. WiFi can work but may not be sufficient or reliable under sustained high camera bitrates.
- **UPS**: Anything that can signal a clean shutdown when battery gets low

### Why these choices

- **ARM host** for native AArch64 execution of Debian and the UniFi binaries (which are compiled for the UNVR's ARM64 architecture).
- **USB 3.2 Gen 2 (10Gbps) DAS** because it provides plenty of headroom for both video writes and database I/O. Anything slower works at smaller scales but cuts your future options.
- **SSD for postgres** because the Protect database determines how snappy the UI feels. Every face search, every timeline scroll, every smart detection query goes through postgres. On spinning storage shared with camera writes and swap, this is the #1 source of perceived slowness.
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

- **`/dev/vda`** (qcow2 on host disk): VM's operating system, around 32GB.
- **`/dev/sd?`** (RAID from DAS or single qcow2): Mounted at `/volume1`, symlinked to `/srv`. Holds camera recordings under `/srv/unifi-protect/` and Access data under `/srv/unifi-access/`.
- **`/dev/sd?`** (qcow2 or SSD passthrough, separate device): Mounted at `/srv/postgresql`. Holds the postgres databases (Access and Protect clusters).
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
- Don't want postgres on a separate disk? Skip the `mount-storage.sh postgres-migrate` step.
- Want to add monitoring, log shipping, additional storage tiers, encrypted volumes, network policy, anything else Linux supports? Add it. It's a VM.
- Want a completely different distro? The install script is bash and dpkg-driven; porting to Ubuntu or any other Debian derivative is straightforward.

The scripts in this repo encode one working configuration that handles the UNVR-shaped corner cases. They're a starting point, not a constraint.

### Why postgres on a separate disk

When postgres lives on the same RAID as camera recordings, every search query waits for the spinning disks to seek away from continuous write operations. The disks never get a quiet moment to handle scattered small reads — which is the pattern postgres uses for face lookups, timeline queries, and smart detection event scans.

In my setup, moving postgres to a dedicated SSD:

- Took face search latency from 4 minutes to under 2 seconds
- Eliminated repeated Protect crashes during heavy use
- Eliminated "An unknown error occurred" when reassigning face matches
- Significantly improved smart detection response time
- Stopped missing image snapshots in event entries

The database working set is small — in my setup, around 2.4GB. A 16GB qcow2 would be plenty for most setups; 50GB gives a lot of headroom.

**After migration, the script leaves a safety backup** at `/srv/postgresql.old.<timestamp>` (the original location, renamed). This is intentional — if anything goes wrong with the new postgres setup, you can revert. Once you've verified Protect, Access, and face search all work normally on the new disk, you can delete this backup:

```bash
rm -rf /srv/postgresql.old.*
```

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
       -drive if=pflash,unit=1,file="$EFI_VARS" \
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
       -drive if=pflash,unit=1,file="$EFI_VARS" \
       -drive if=virtio,file="$VM_DISK",format=qcow2 \
       -device virtio-scsi-pci,id=scsi0 \
       -drive if=none,id=scripts,file="$SCRIPTS_ISO",format=raw,media=cdrom \
       -device scsi-cd,bus=scsi0.0,drive=scripts \
       -netdev user,id=net0 \
       -device virtio-net-pci,netdev=net0 \
       -nographic
   ```

9. **Inside the VM, mount the ISO and copy the scripts**:
   ```bash
   sudo mkdir -p /mnt/protect-on-mac
   sudo mount /dev/sr0 /mnt/protect-on-mac
   sudo cp /mnt/protect-on-mac/*.sh /root/
   sudo chmod +x /root/*.sh
   sudo umount /mnt/protect-on-mac
   ```
   We mount at `/mnt/protect-on-mac` rather than `/mnt` directly so we don't shadow anything Protect or related software might want to use there in the future. The scripts get copied to `/root/` so they're available even when the ISO isn't mounted.

10. **Run the install script**:
    ```bash
    sudo bash /root/install-protect-baremetal.sh
    ```
    This downloads the UNVR firmware, extracts the Ubiquiti packages, adds `apt.artifacts.ui.com` as an apt repository at `/etc/apt/sources.list.d/ubiquiti.list`, and installs everything.

11. **Reboot the VM**, this time using `start-protect-vm.sh` from the host (which switches to bridged networking and attaches your DAS disks). The scripts ISO is no longer needed; the scripts are now in `/root/`.

12. **Access `https://<VM-IP>`** for initial UniFi setup. Once the VM is on bridged networking, other LAN hosts can also reach it — useful for future script updates via `scp` from a non-host machine, or just rebuild the ISO with `make-scripts-iso.sh` and re-attach.

### Refreshing scripts in the VM later

When the scripts on the host change (you pulled an update from the repo, edited something locally, etc.) and you want the VM to have the new versions:

1. Run `start-protect-vm.sh` interactively. It'll see the existing ISO and ask if you want to regenerate it. Answer yes.
2. Reboot the VM (or just attach the ISO via QMP, but reboot is simpler).
3. Inside the VM: `sudo mount /dev/sr0 /mnt/protect-on-mac && sudo cp /mnt/protect-on-mac/*.sh /root/`

The ISO is also fine to leave attached permanently — the VM ignores it in normal operation. You can `mount /dev/sr0` any time you want to refresh scripts from whatever the latest ISO contains.

### Migration from existing UNVR

This is the recommended workflow if you have a working UNVR you want to replace:

1. **Backup the UNVR** via the web UI. Download the backup file.

2. **Build the test VM** following the fresh install workflow above (install script, no production data yet).

3. **Important: Do NOT remove cameras from the original UNVR's Protect**. The backup includes camera adoption state and certificates. If you remove cameras from Protect first, the backup won't bring them back automatically.

4. **Shut down the original UNVR cleanly** via its web UI. This is critical — clean shutdown ensures the disks are in a consistent state and lets cameras gracefully drop their connection.

5. **Restore the UNVR backup onto the VM** via the VM's Protect web UI. This includes camera configurations, Access doors, users, face data, and certificates.

6. **Verify a few cameras come online** in the VM's Protect UI before proceeding. The cameras find the new controller via cached IP / cloud rediscovery, and the matching certificates from the backup let them adopt automatically.

7. **Once you're confident**, move the UNVR's disks to the DAS, connect to the host, and run `mount-storage.sh import` inside the VM. This attaches the existing video storage.

8. **If some cameras don't come back automatically**, give them a few minutes for the controller to make contact and the cameras to reconcile. If they still don't connect after that, they may need to be re-adopted in the Protect UI.

9. **Optionally migrate the database to SSD** for the UI speedup:
   ```bash
   ./mount-storage.sh postgres-migrate /dev/sdX
   ```
   The script asks which SSD to use if you don't specify one.

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
ssh root@<VM-IP> /root/unifi-update.sh --all

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

**What gets snapshotted**: the VM rootfs qcow2 and any image files listed in `STORAGE_IMAGES` (typically the postgres SSD image). Raw disk passthrough (bulk recording disks) is NOT snapshotted — those are real block devices, often 10+ TB, where qcow2-style snapshotting isn't practical. This asymmetry is fine: an update that breaks the controller can be rolled back via the qcow2 snapshots, and the recordings on the RAID continue uninterrupted.

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

Once running, updates are handled by `unifi-update.sh`:

```bash
./unifi-update.sh              # Show what's available
./unifi-update.sh --check      # Same as default
./unifi-update.sh --sync-os    # Update UniFi OS packages from latest UNVR firmware
./unifi-update.sh --protect    # Update Protect to latest stable
./unifi-update.sh --access     # Update Access to latest stable
./unifi-update.sh --all        # Sync OS + upgrade Protect + Access
./unifi-update.sh --all-edge   # Same but use beta channels
```

The script queries Ubiquiti's firmware API (the same one the UNVR uses to find updates) and downloads the latest debs directly. Checksum verification on every download.

### Should I run `apt-get upgrade`?

**Short answer**: yes, it's safe. The install script holds all the Ubiquiti packages, so `apt-get upgrade` will skip them and only upgrade Debian-side packages (kernel, openssl, libraries, etc.).

When you run `apt-get upgrade` you'll see a message like:

```
The following packages have been kept back:
  ds  unifi-access  unifi-core  unifi-protect  ulp-go  ...
```

That's intentional and correct — those packages are managed by `unifi-update.sh`, not by apt. Held packages get skipped during `apt-get upgrade` so a routine system update can't break your Protect install.

**What's safe to upgrade via apt**:

- Debian base system packages (kernel, openssl, glibc, etc.) — security and bugfix updates
- PostgreSQL minor versions (14.x → 14.y) — postgres handles these in place
- Build tools, libraries, supporting utilities

**What you should NOT do**:

- **Don't `apt-mark unhold` the Ubiquiti packages unless you know what you're doing.** Use `unifi-update.sh` instead — it coordinates the version handling and unholds/re-holds the packages around its operations.
- **Avoid `apt-get dist-upgrade`** unless you understand exactly what it's doing. Unlike plain `upgrade`, `dist-upgrade` can install new packages and remove existing ones to satisfy dependencies. This could reintroduce `unvr-initramfs` (which we deliberately removed because it breaks VM boot) or install other UNVR-only packages.
- **PostgreSQL major versions (14 → 15)** would require a full migration with `pg_upgradecluster`. Not normally pushed by Debian stable, but worth being aware of as bullseye approaches end-of-life.

**Service masks survive upgrades**. The `usd`, `usdbd`, `rpsd`, `uhwd`, `sfp`/`sfpd` masks installed during setup are at the systemd level, not the package level. Package upgrades won't undo them. New services introduced by a UniFi OS update might need to be masked too — `unifi-update.sh --sync-os` handles the known ones automatically.

**Unattended upgrades**: if you want automatic security patches, install `unattended-upgrades` and configure it for security-only updates. Since the Ubiquiti packages are already held, unattended-upgrades will leave them alone automatically.

## Optional: smartctl proxy (real disk health in Protect)

By default the installer drops a fake `/usr/sbin/smartctl` into the VM that always reports a healthy virtual disk. That keeps Protect happy, but it means Protect's UI can never warn you about a disk that's actually dying — bad sectors, climbing reallocated-sector counts, SMART failures. The data lives on USB-attached disks on the Mac; the VM only ever sees virtio-scsi devices with no real SMART data.

The smartctl proxy bridges that gap. The fake `smartctl` is replaced with a wrapper that forwards SMART queries back to the Mac, which *can* read the physical disks over USB. Protect then shows genuine per-disk health.

This is **optional and opt-in**. If you don't set it up, nothing changes — the fake `smartctl` is used and the VM behaves exactly as before.

### How it works

1. Protect runs `smartctl <flags> /dev/sdX` inside the VM.
2. The VM-side wrapper resolves `/dev/sdX` to its disk serial (via `lsblk`).
3. It SSHes to the Mac with a key locked to a single forced command, passing the serial and flags.
4. The host helper validates the input, looks the serial up in a serial-to-device map (`disk-serial.map`, rewritten by `start-protect-vm.sh` on every VM start — macOS renumbers `/dev/diskN` constantly), and runs the real `smartctl` against the matching `/dev/diskN`.
5. The output travels back and the wrapper hands it to Protect.

If anything fails — proxy not configured, Mac unreachable, unknown disk, SSH error — the wrapper falls through to the local real `smartctl`. The proxy is strictly best-effort; it can't break the VM.

Only **raw-passthrough disks** (`DISK_SERIALS` in `protect-on-mac.conf`) are proxied. qcow2 disk images have no underlying physical disk, so they keep returning local data.

### Prerequisite: SAT SMART pass-through on the Mac

macOS does **not** expose ATA/SMART pass-through for USB-attached disks natively. You need the kasbert `OS-X-SAT-SMART-Driver` kext — most easily obtained by installing [DriveDx](https://binaryfruit.com/drivedx), which bundles and installs it. On Apple Silicon, loading a third-party kext requires **Reduced Security** mode (set in the recoveryOS Startup Security Utility). See "Limitations and known issues" below — this is a real dependency, not a footnote.

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

**1. Install the VM with the proxy enabled.** Run the bare-metal installer with `SMARTCTL_PROXY=1`:

```bash
SMARTCTL_PROXY=1 sudo bash /root/install-protect-baremetal.sh
```

This installs real `smartmontools` (as `/usr/sbin/smartctl.real`), the wrapper at `/usr/sbin/smartctl`, a config file at `/etc/default/smartctl-proxy`, and generates an SSH keypair under `/etc/protect-smartctl-proxy/`. The installer prints the VM's public key at the end — keep it.

(Already installed without the proxy? Re-run Phase 7's logic by re-running the installer with the flag, or set it up by hand following the same file layout.)

**2. Point the VM at the Mac.** Edit `/etc/default/smartctl-proxy` in the VM:

```sh
PROXY_HOST=192.168.1.50        # the Mac's LAN IP
PROXY_USER=donnie              # your macOS username
PROXY_KEY=/etc/protect-smartctl-proxy/id_ed25519
```

**3. On the Mac — install smartmontools and enable Remote Login:**

```bash
brew install smartmontools
# System Settings → General → Sharing → Remote Login (on)
```

**4. On the Mac — install the host helper:**

```bash
sudo cp smartctl-host-helper.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/smartctl-host-helper.sh
```

The helper's `DISK_MAP` path must match `DISK_MAP` in `protect-on-mac.conf`. Both default to `$VM_DATA_DIR/disk-serial.map`, so if you didn't change `VM_DATA_DIR` there's nothing to do.

**5. On the Mac — add the sudoers rule.** The helper needs root to read raw disks:

```bash
sudo visudo -f /etc/sudoers.d/smartctl-proxy
# Add this line (replace `donnie` with your username):
#   donnie ALL=(root) NOPASSWD: /opt/homebrew/bin/smartctl
```

**6. On the Mac — authorize the VM's key with a forced command.** Add the public key the installer printed to `~/.ssh/authorized_keys`, prefixed so the key can *only* run the helper:

```
command="/usr/local/bin/smartctl-host-helper.sh",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA...the VM's public key... protect-smartctl-proxy
```

Optionally tighten further with `from="<VM-IP>"` at the front of that line.

### Verify

From inside the VM:

```bash
# Pick a raw-passthrough disk, e.g. /dev/sda
smartctl -a /dev/sda
```

If the proxy is working you'll see the real disk's model, serial, temperature, and SMART attributes — not the fake "Virtual Storage Device". A failing disk shows `SMART overall-health self-assessment test result: FAILED` to anything that runs `smartctl`. Whether Protect's *Storage Manager panel* renders that is a separate, unresolved matter — see [Storage health and the Storage Manager panel](#storage-health-and-the-storage-manager-panel) below.

To watch what the proxy is doing, the host helper writes diagnostics to stderr (visible in the VM via SSH stderr) and `start-protect-vm.sh` prints the disk-map path and count on every start.

### Caveats

- **Per-disk only.** RAID devices (`/dev/md3`) have no single serial, so a `smartctl` call against the array falls back to local data. Protect mostly queries individual disks, which is what gets proxied.
- **The map is only as fresh as the last VM start.** If you hot-swap a disk while the VM is running, the map is stale until the next `start-protect-vm.sh`. The wrapper falls back gracefully in the meantime.
- **State-changing flags are refused.** The host helper only ever runs read-only SMART queries — it rejects self-test triggers (`-t`), `--set`, and SMART enable/disable. Protect doesn't need those.

## Storage health and the Storage Manager panel

The smartctl proxy is one piece of a larger goal: **getting real disk health — and disk-failure alerts — into Protect on a VM.** This section is an honest account of what works, what doesn't, and why.

### The goal

On a real UNVR, a failing disk turns the Storage panel red ("Drive Failure Detected") and raises an alert. The aim here is the same on the VM: a dying disk in the DAS should be *noticed*, not silently ignored behind a faked-healthy virtual disk.

### What works

- **`smartctl` returns real data.** With the smartctl proxy (`smartctl-vm-wrapper.sh` + `smartctl-host-helper.sh`), any `smartctl` call in the VM is forwarded to the Mac and answered with genuine SMART data for the real USB-attached disks.
- **`ustorage` returns real data.** `ustorage-vm.py` replaces the installer's static fake `/usr/bin/ustorage` with a dynamic one that reports real per-disk health and array state — including failure detection from both SMART *and* md-array member state (a dropped disk shows as `faulty`).
- **`mdadm --detail /dev/md3` works on migrated arrays.** `mdadm-vm-wrapper.sh` redirects that hardcoded call (UniFi software always asks for `/dev/md3`) to whatever device the imported array actually assembled as (`/dev/md12x` on a migration).
- **`unifi-core`'s background storage health poll runs on real data.** Once the `unifi-core` → `smartctl` sudoers rule is in place, the every-60-seconds storage check succeeds with genuine SMART instead of failing.

### What doesn't — the Storage Manager panel

The UniFi OS **Storage Manager panel** (Settings → Control Plane → Storage) does not render — it sits on a loading spinner.

The cause is architectural. The panel is driven by `ucore`'s live `system.ustorage` object, and `ucore` builds the disk portion of that object with help from **`usd`**, the UNVR storage daemon. `usd` cannot run on this VM: it's built for the UNVR's read-only-squashfs + overlay-root boot layout and crashes resolving the root volume on a normal Debian install. With `usd` dead, `ucore`'s `ustorage.disks` stays empty and the panel waits forever.

Things that were *ruled out* along the way, in case it saves someone else the trip: it is not the `md3`-vs-`md12x` naming (fixed by the wrapper), not the `smartctl` sudo denial (fixed by the sudoers rule), and not the `usd`↔`usdbd` status database (populating it directly had no effect — the panel doesn't read it).

### The aim / open work

Disk health *is* on the box and queryable today — by CLI, by script, and by `unifi-core`'s health poll. The remaining goal is the UI/alert path: making a failing disk visibly raise an alert in Protect. The route under exploration is a small daemon that supplies `ucore` the storage data `usd` normally would, without `usd`'s VM-incompatible code. That work is unfinished.

## Migrating back to a real UNVR (or ENVR, or other host)

If you decide to go back to a real UNVR, upgrade to an ENVR, or move to a different VM host, the reverse-migration workflow is close to the forward one — backup-first, restore on the new system, then move the disks for the recording history.

**Workflow**:

1. **Back up Protect and Access** via the VM's web UI. Download both backup files (Protect and Access have separate backups).
2. **Run `uninstall.sh migrate`** inside the VM. This moves postgres back from the dedicated SSD (if applicable) to `/srv/postgresql` on the spinning RAID, so the disks contain a complete UNVR-style layout.
3. **Cleanly shut down the VM**: `systemctl poweroff`
4. **Remove the disks** from the DAS.
5. **Install the disks** in the target hardware (real UNVR, ENVR, etc.).
6. **Power on the target hardware**. It should boot to its initial setup state, or come up with what's on the disks depending on the target's behavior.
7. **Restore the Protect and Access backups** via the target's web UI, the same way you'd restore on any new UniFi controller. This brings camera configurations, doors, users, face data, and certificates over.
8. **Cameras automatically re-adopt** to the new controller within a few minutes, using the cached identity from the restored backup.

This mirrors the forward migration: backup-first carries the configuration, the disks carry the recording history, and the restore on the target stitches them back together. The cameras don't care which hardware their controller runs on as long as the certificates match.

**Helper commands**:

```bash
./uninstall.sh status      # Show what migrate would change
./uninstall.sh migrate     # Move postgres back to the RAID
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
- **The Storage Manager panel doesn't render**. The UniFi OS Storage panel sits on a loading spinner — it depends on the `usd` daemon, which can't run on a VM. Real disk health is still available via `smartctl`/`ustorage` and `unifi-core`'s health poll; only the visual panel is affected. See [Storage health and the Storage Manager panel](#storage-health-and-the-storage-manager-panel).

## Possible future enhancements

- **Fully automated VM creation**: A script that creates the qcow2, boots the Debian installer with a preseed file, runs the install script, and produces a ready-to-go VM image. Doable, just not done yet.

## Files

VM-side (live inside the Debian VM):

- **`install-protect-baremetal.sh`** — full UniFi software install. Run once during initial setup.
- **`unifi-update.sh`** — query API, download, install latest UniFi packages.
- **`mount-storage.sh`** — import existing RAID, migrate postgres to SSD, show status.
- **`uninstall.sh`** — migrate postgres back to the RAID to prep disks for moving to other hardware.
- **`smartctl-vm-wrapper.sh`** — VM side of the optional smartctl proxy. Installs as `/usr/sbin/smartctl`; forwards SMART queries to the Mac host. See the "smartctl proxy" section.
- **`smartctl-proxy.conf.example`** — config template for the proxy wrapper. Copy to `/etc/default/smartctl-proxy` in the VM.
- **`ustorage-vm.py`** — dynamic `ustorage` replacement: reports real per-disk and array health instead of the installer's static fake. See "Storage health".
- **`mdadm-vm-wrapper.sh`** — redirects `mdadm --detail /dev/md3` to the real array on migrated setups. See "Storage health".

Host-side (live on the Mac):

- **`protect-on-mac.conf.example`** — configuration template. Copy to `protect-on-mac.conf` and edit.
- **`start-protect-vm.sh`** — start the VM with stable hardware references. Sources the config.
- **`make-scripts-iso.sh`** — bundle the VM-side scripts into an ISO for initial bootstrap (when scp from host can't reach the VM).
- **`attach-console.sh`** — attach to the VM's serial console for emergency access when running as a daemon.
- **`snapshot.sh`** — create/restore/list/delete qcow2 snapshots before risky operations.
- **`install-launchd.sh`** — install/manage the launchd daemon that auto-starts the VM at boot.
- **`com.protect-on-mac.vm.plist`** — launchd configuration template used by `install-launchd.sh`.
- **`smartctl-host-helper.sh`** — host side of the optional smartctl proxy. Forced-command target that returns real disk SMART data to the VM. See the "smartctl proxy" section.

## Credits

This work is built on:

- [dciancu/unifi-protect-unvr-docker-arm64](https://github.com/dciancu/unifi-protect-unvr-docker-arm64) — the Docker-based approach that proved Ubiquiti's binaries could run on non-UNVR hardware. The package extraction and hardware spoofing patterns originated there.
- Ubiquiti's UNVR firmware and packages. These are not redistributed by this project — the install and update scripts (run by you) download them directly from Ubiquiti's official servers (`fw-download.ubnt.com` for firmware, `apt.artifacts.ui.com` for packages). The scripts add Ubiquiti's apt repo to `/etc/apt/sources.list.d/ubiquiti.list` so future package updates pull from official sources.
- Vibe-coded with [Claude](https://claude.ai), which dramatically reduced the time from idea to working solution and produced the extensive inline documentation throughout.

## License

Scripts in this repository are MIT licensed. Ubiquiti software is owned by Ubiquiti Inc. and subject to their license — downloading and using it is your responsibility.
