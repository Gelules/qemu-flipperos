# QEMU FlipperOS

Boot **FlipperOS**, the Debian-based Linux system of the Flipper One, in
**QEMU** on an ordinary Linux PC: no Flipper One and no single-board computer
needed.

The scripts download an official FlipperOS build, take the kernel, the initrd
and the kernel command line out of the disk image, and boot it on QEMU's
generic `virt` ARM machine. You get the FlipCTL user interface in your
browser, SSH and a console in your terminal. When a new build is published,
one command prepares it.

> **Unofficial project.** QEMU FlipperOS is not affiliated with, endorsed by
> or supported by Flipper Devices. FlipperOS, Flipper One and FlipCTL belong
> to their owners. Please do not report problems seen under QEMU to Flipper
> Devices unless you also see them on real hardware.

## Contents

1. [Requirements](#requirements)
2. [Quick start](#quick-start)
3. [Which file to download](#which-file-to-download)
4. [Updating to a new FlipperOS build](#updating-to-a-new-flipperos-build)
5. [Profiles](#profiles)
6. [Configuration](#configuration)
7. [How it works](#how-it-works)
8. [Limitations and troubleshooting](#limitations-and-troubleshooting)
9. [Going further (untested)](#going-further-untested)
10. [Links and credits](#links-and-credits)

## Requirements

- A Linux host (tested on Arch Linux, x86_64). The ARM guest is fully
  emulated (there is no KVM for an ARM guest on an x86 host), which is
  fine: a boot takes well under a minute on a recent laptop.
- The packages below. `./scripts/00-check-host.sh` checks them and prints the
  install command for your distribution.

  | Distribution | Command |
  |---|---|
  | Arch Linux | `sudo pacman -S --needed curl zstd coreutils util-linux qemu-system-aarch64 qemu-img sshpass sudo` |
  | Debian, Ubuntu | `sudo apt install curl zstd coreutils fdisk mount qemu-system-arm qemu-utils sshpass sudo` |
  | Fedora | `sudo dnf install curl zstd coreutils util-linux qemu-system-aarch64-core qemu-img sshpass sudo` |

  `sshpass` is optional: only the smoke test uses it, to log into the guest.
  Only the Arch Linux setup has been tested; the other lines give the usual
  package names.
- **Disk space**: about 10 GB for one build. The download (2 GB) is deleted
  once decompressed; the raw image is 6 GiB but stored sparse (about 3.2 GB);
  the VM disk then grows with what the guest writes.
- **RAM**: the guest gets 4 GB by default (`MEMORY`); 2 GB also works.
- **sudo, once per build**: the scripts mount the root partition of the image
  (read-only, through a loop device) to copy the kernel and the initrd. This
  needs root, so `03-extract-boot.sh` runs `sudo mount` and asks for your
  password. Nothing else needs root. If you cannot use sudo, mount the
  partition another way and point `ROOT_MOUNT` at it
  ([see below](#mounting-without-sudo)).
- **loop and btrfs drivers** in the host kernel, as in every common
  distribution. After a kernel upgrade, reboot before running the scripts:
  until then the modules of the running kernel are often missing and the
  mount fails.

## Quick start

```sh
git clone https://github.com/Gelules/qemu-flipperos.git
cd qemu-flipperos
./scripts/setup.sh latest    # check, download (2 GB), extract, create the VM disk
./scripts/05-run.sh          # boot; the console is in this terminal
```

`setup.sh` asks for your sudo password once, to mount the image. Then:

- **Console**: it stays silent for about 20 seconds (see
  [why](#the-console-stays-silent-at-the-start)), then shows the boot
  messages and a login prompt. User `user`, password `user`.
- **FlipCTL**, the Flipper One user interface, in a browser:
  <http://localhost:8899>. Use the mouse on the buttons of the device
  picture, or the keyboard: arrows, Enter (OK), Escape or Backspace (Back),
  and the keys listed under "Show controls".
- **SSH**: `ssh -p 2222 user@localhost`, password `user`. FlipperOS gives
  `user` passwordless sudo. A new build or a fresh VM disk comes with new SSH
  host keys: if `ssh` then refuses to connect because the host key changed,
  forget the old one with `ssh-keygen -R '[localhost]:2222'`.
- **Quit**: run `sudo poweroff` in the guest, or press `Ctrl-a` then `x` in
  the terminal (this stops QEMU at once, like pulling the plug). `Ctrl-a c`
  switches between the console and the QEMU monitor.

Everything you change in the VM is kept in `work/<BUILD_ID>/disk.qcow2` for
the next `05-run.sh`. The downloaded image itself is never modified.

To check that everything works without opening a terminal session in the VM:

```sh
./scripts/06-smoke-test.sh   # headless boot + automated checks, about one minute
```

## Which file to download

The scripts do all of this for you; this section explains what they do, and
how to do it by hand.

### Where the builds are

Flipper Devices publishes every successful build of FlipperOS on
<https://dl-linux-images.flipp.dev/full-img/>, one directory per build. The
page is drawn in the browser by JavaScript from
[`manifest.json`](https://dl-linux-images.flipp.dev/full-img/manifest.json);
each build directory also has a `manifest.json` that lists its files with
their size and SHA-256 checksum. Scripts should read these manifests:
`curl` works with its default user agent, but the directory URLs need their
trailing slash (`.../full-img` without it gives a 404).

The builds are made by the [Buildbot](https://linux-images.flipp.dev/) of
Flipper Devices ("full-img" builder). Builds older than about 30 days are
deleted, even if the listing still shows them for a while.

### Build IDs

A build ID is the Buildbot build number, optionally followed by a label:
`2407`, `2410-test-falcon`. Numbers missing from the list are builds that
failed or were cancelled.

- **No label**: a regular build, made from the default branch of every
  source repository.
- **With a label**: usually a test build. As seen in the Buildbot data, the
  label is one of:
  - the name of a branch that is not the default one, for example
    `2410-test-falcon` (U-Boot branch `test-falcon`);
  - a pull request, `<codebase>-<number>`, where the codebase is Buildbot's
    short name of the repository, for example `2392-buildscripts-190` (pull
    request 190 of flipperone-linux-build-scripts);
  - a build started by hand, `<person>-<reason>`, for example
    `2408-y-smirnov-force-build-for-updater-test`;
  - `bundle-nightly`, a build triggered by the nightly update bundle.

**`latest` means the newest build without a label.** To use a labelled build,
give its full ID: `./scripts/setup.sh 2410-test-falcon`.

Note that `/etc/os-release` inside the image has another number, for example
`BUILD_ID=1243`: the number of the root file system build that the disk
image was assembled from. Several disk image builds can share one root file
system build.

### Finding the newest build

With the scripts:

```sh
./scripts/01-list-builds.sh          # every build, newest first, and which one is "latest"
./scripts/01-list-builds.sh latest   # the files of the newest unlabelled build
```

Without them, list the directory names and sort them by number:

```sh
# Every build, newest first.
curl -s https://dl-linux-images.flipp.dev/full-img/manifest.json |
    grep -o '"name": *"[^"]*"' | cut -d '"' -f 4 | tr -d / | sort -n -r | head

# The newest build without a label (what the scripts call "latest").
curl -s https://dl-linux-images.flipp.dev/full-img/manifest.json |
    grep -o '"name": *"[0-9]*/"' | cut -d '"' -f 4 | tr -d / | sort -n -r | head -n 1
```

### The files of a build

Each build directory holds 20 files: a disk image and its block map for
each of 10 targets.

| File | Use it? | Why |
|---|---|---|
| `debian-512-nobootloader-<ID>.img.zst` | **Yes** | The complete disk (GPT partition table + root file system) without any bootloader: exactly what QEMU needs. |
| `debian-512-<board>-<ID>.img.zst` | Fallback | The same disk with the U-Boot of one board written in its first megabytes. QEMU never runs that code, so it works too. Boards: `sige5` (ArmSoM Sige5, Banana Pi BPI-M5 Pro), `flipper-one`, `generic`, `evb`, `nanopi-m5`, `nanopi-r76s`, `omni3576`, `roc-pc` (Firefly ROC-RK3576-PC), `rock-4d`. |
| `*.img.bmap` | No | Block maps, to flash a card faster with bmaptool. Not needed to decompress or run the image. |
| `debian-4096-*` | Never | Old images for UFS storage, with 4 KiB sectors: their partition table cannot be read on a 512-byte-sector virtual disk. No longer built since September 2026. |
| `debian-rootfs.img.zst`, `debian-ospack.tar.zst` | No | Not in the full-img directories (they are intermediate products, published elsewhere): the bare root file system without a partition table, and a tarball of the base system. |

`02-download.sh` takes the first variant of `IMAGE_VARIANTS` that exists:
`nobootloader`, then `sige5`. It never takes a `debian-4096` image.

Example, the build tested last (2407):

```text
https://dl-linux-images.flipp.dev/full-img/2407/
    debian-512-nobootloader-2407.img.zst   1.9 GiB  <- used
    debian-512-nobootloader-2407.img.bmap
    debian-512-sige5-2407.img.zst          1.9 GiB  <- fallback
    debian-512-sige5-2407.img.bmap
    ... (evb, flipper-one, generic, nanopi-m5, nanopi-r76s, omni3576, roc-pc, rock-4d)
```

The decompressed image is a 6 GiB disk with three GPT partitions: `loader`
(U-Boot, empty here), `metadata`, and `root`, a btrfs file system labelled
`flipperos` that holds every profile.

### By hand

```sh
ID=2407
URL=https://dl-linux-images.flipp.dev/full-img/$ID

# The file list, with the SHA-256 of each file.
curl -s "$URL/manifest.json"

# Download (-C - resumes an interrupted download, -f gives up on an error
# instead of saving the error page), then check the checksum.
curl -f -C - -O "$URL/debian-512-nobootloader-$ID.img.zst"
sha256sum debian-512-nobootloader-$ID.img.zst

# Decompress. --sparse is important: without it, zstd 1.5 writes all the
# zeros and the image takes 6 GiB on disk instead of about 3.2 GB.
zstd --decompress --sparse debian-512-nobootloader-$ID.img.zst -o image.img
```

## Updating to a new FlipperOS build

```sh
./scripts/setup.sh latest && ./scripts/05-run.sh
```

Each build gets its own directory, `work/<BUILD_ID>/`, with its own VM disk:
nothing is shared between builds, and `work/current` points to the build set
up last (the one the scripts use when you give no build ID). Running
`setup.sh` again on a build that is already prepared only checks it and
changes nothing.

To go back to an older build: `./scripts/05-run.sh 2405`. To free space:
`rm -rf work/2405`.

To start again from a fresh VM disk of a build (everything changed inside
the VM is lost): `./scripts/04-create-disk.sh --force 2407`.

## Profiles

FlipperOS comes with several *profiles*: complete systems that share the same
btrfs file system, each in its own subvolume (`@Minimal`, `@Router`...).
`/home`, `/var/log`, `/var/cache` and `/boot` are shared by all profiles.

| Profile | Under QEMU | Notes |
|---|---|---|
| `Minimal` | Works | The reference, booted by default. FlipCTL, SSH, network, NTP. Smoke test passes. |
| `No-Graphics` | Works | Minimal with the video hardware disabled by a device-tree overlay, which QEMU ignores: same as Minimal here. Smoke test passes. |
| `Router` | Boots, no network | Its network setup only uses the board's Ethernet ports and Wi-Fi, so the VM's network card gets no address: FlipCTL and SSH cannot be reached, and the smoke test fails. Use the console, see [Router has no network](#router-has-no-network). |
| `Desktop` | Boots, nothing to see | KDE Plasma, Chromium, mpv. The session starts, but there is no display under QEMU (see [limitations](#desktop-and-tv-media-box-show-nothing)). FlipCTL and SSH work; smoke test passes. |
| `TV-Media-Box` | Boots, nothing to see | Kodi and HDMI-CEC. Kodi waits forever for a screen; FlipCTL and SSH work; smoke test passes. |

On real hardware a fresh image boots `Desktop`; here `PROFILE` decides, and
it is `Minimal` by default. To boot another profile:

```sh
PROFILE=No-Graphics ./scripts/05-run.sh      # or: ./scripts/05-run.sh --profile No-Graphics
PROFILE=No-Graphics ./scripts/06-smoke-test.sh
```

`03-extract-boot.sh` prints the profiles found in the image, and
`work/<BUILD_ID>/build-info.txt` lists them.

FlipCTL's boot menu cannot switch profiles under QEMU (it even shows no
profiles, [see why](#flipctls-boot-menu-shows-no-profiles)). Choose the
profile on the command line instead.

**A profile created inside the VM.** The profile tools of FlipperOS work in
the VM. For example, to make a copy of Minimal and boot it:

```sh
# Inside the VM:
sudo create-profile -y @Minimal @MyProfile
sudo poweroff

# On the host: boot @MyProfile with the kernel of Minimal.
ROOT_SUBVOL=@MyProfile ./scripts/05-run.sh
```

The new profile only exists in the VM disk, not in the downloaded image, so
the scripts cannot find its kernel by themselves: `ROOT_SUBVOL` boots it with
the kernel and initrd of `PROFILE`. This works as long as both have the same
kernel version, which is the case for a copy. (The smoke test ignores
`ROOT_SUBVOL`: it boots a fresh copy of the image.)

## Configuration

Settings live in [`config.env`](config.env). Every one can be overridden with
an environment variable of the same name, for example
`MEMORY=2G CPUS=2 ./scripts/05-run.sh`.

| Variable | Default | Meaning |
|---|---|---|
| `BASE_URL` | `https://dl-linux-images.flipp.dev/full-img` | Build server directory. |
| `BUILD_ID` | `latest` | Build prepared by `setup.sh` and `02-download.sh`: an ID, or `latest` (newest build without a label). |
| `IMAGE_VARIANTS` | `nobootloader sige5` | Image variants to look for, in order of preference. |
| `WORK_DIR` | `work` | Where downloads, kernels, VM disks and logs go. |
| `PROFILE` | `Minimal` | Profile to boot. |
| `ROOT_SUBVOL` | (empty) | Boot this subvolume, for example `@MyProfile`, with the kernel of `PROFILE`. |
| `MEMORY` | `4G` | Guest RAM. |
| `CPUS` | `4` | Number of virtual CPUs. |
| `CPU_MODEL` | `cortex-a72` | Emulated CPU: the big cores of the RK3576. `max` boots faster with QEMU 11 (FlipCTL answers after 25 s instead of 31 s here), but gives the guest CPU features the RK3576 does not have. |
| `DISK_SIZE` | `16G` | Size of the VM disk; the root file system grows to fill it at the first boot. |
| `BIND_ADDR` | `127.0.0.1` | Host address the forwarded ports listen on. |
| `FLIPCTL_PORT` | `8899` | Host port for the FlipCTL remote view (guest port 8899). |
| `SSH_PORT` | `2222` | Host port for SSH (guest port 22). |
| `TEST_FLIPCTL_PORT` | `18899` | FlipCTL port of the smoke test. |
| `TEST_SSH_PORT` | `12222` | SSH port of the smoke test. |
| `BOOT_TIMEOUT` | `600` | Seconds the smoke test waits for the guest to answer. |
| `NTP_TIMEOUT` | `120` | Seconds the smoke test waits for the guest clock to be set by NTP. |
| `GUEST_USER`, `GUEST_PASSWORD` | `user`, `user` | Account used by the smoke test. |
| `ROOT_MOUNT` | (empty) | For `03-extract-boot.sh` only: read the image from this already mounted root partition instead of mounting it with sudo. |

**Security.** The forwarded ports listen on 127.0.0.1 only. If you set
`BIND_ADDR=0.0.0.0`, anyone on your network can log in over SSH with the
well-known password `user` (and get root through sudo), and can use FlipCTL,
which has no authentication at all. Change the password first.

## How it works

### The scripts

| Script | Does |
|---|---|
| `scripts/00-check-host.sh` | Checks the programs, the host kernel drivers, the disk space and the RAM. |
| `scripts/01-list-builds.sh` | Lists the builds on the server, or the files of one build. |
| `scripts/02-download.sh` | Downloads the image (resumable), checks its SHA-256, decompresses it. |
| `scripts/03-extract-boot.sh` | Mounts the root partition read-only and copies the kernel, initrd and command line of every profile. |
| `scripts/04-create-disk.sh` | Creates the VM disk, a copy-on-write overlay on top of the image. |
| `scripts/05-run.sh` | Boots the VM with the console in the terminal. |
| `scripts/06-smoke-test.sh` | Boots the VM headless on a throwaway disk and checks that it works. |
| `scripts/setup.sh` | Runs 00, 02, 03 and 04 for one build. |
| `scripts/lib.sh` | Code shared by the scripts, including the QEMU command line. |

Each script starts with a description of what it does, its inputs and its
outputs (`--help` prints it), and every step is commented. The scripts that
prepare a build (02, 03, 04 and `setup.sh`) skip the work that is already
done; `--force` redoes it.

```text
work/
├── current -> <BUILD_ID>  the build set up last (04)
└── <BUILD_ID>/
    ├── image.img          raw disk image, read-only (02)
    ├── build-info.txt     where it comes from, file system UUID, profiles (02, 03)
    ├── boot/<Profile>/    vmlinuz, initrd, cmdline, kernel-version,
    │                      entry.conf, os-release (03)
    ├── disk.qcow2         the VM disk, backed by image.img (04)
    └── logs/              console log of every run and test (05, 06)
```

### Why there is no bootloader

On the hardware, the RK3576 boot ROM runs a DDR initialisation blob, the
Arm Trusted Firmware and a U-Boot built for that board, with the Rockchip
device trees. None of this can run in QEMU, which has no RK3576 model. It is
not needed either: the FlipperOS kernel is a mainline arm64 kernel, which
boots on any machine it has drivers for. So QEMU loads the kernel and the
initrd itself (`-kernel`, `-initrd`, `-append`) on its generic `virt` machine,
and gives it a device tree describing that machine.

```text
 Flipper One / RK3576 board              QEMU (this project)
 ──────────────────────────              ───────────────────
 Boot ROM, DDR blob, TF-A                (nothing)
 U-Boot reads a BLS entry         ──>    03-extract-boot.sh reads the same entry
 U-Boot loads kernel, initrd, DTB        QEMU loads kernel and initrd, makes its own DTB
             │                                          │
             └──── same kernel, same initrd, same root file system ────┘
                   root=UUID=... rootflags=subvol=@<Profile>

 work/<ID>/image.img (read-only)  <── backing file ──  work/<ID>/disk.qcow2 (the VM writes here)
```

### Reading the boot entries

FlipperOS describes what to boot with [Boot Loader
Specification](https://uapi-group.org/specifications/specs/boot_loader_specification/)
entries, in `/boot/loader/entries/` of the btrfs file system: one entry per
profile and per kernel, for example
`600-flipperos-Minimal-7.3.0-rc7-gd66a9f4f3efa+3-0.conf`:

```text
title      Minimal 7.3.0-rc7-gd66a9f4
version    7.3.0-rc7-gd66a9f4f3efa
sort-key   debian-1400-Minimal-0
options    root=UUID=5cf1bcd6-... console=tty1 console=ttyS0,1500000n8 console=ttyS4,1500000n8 fbcon=map:1 rootflags=subvol=@Minimal
linux      /@Minimal/usr/lib/modules/7.3.0-rc7-gd66a9f4f3efa/vmlinuz
devicetreedir /@Minimal/usr/lib/linux-image-7.3.0-rc7-gd66a9f4f3efa
initrd     /@Minimal/usr/lib/modules/7.3.0-rc7-gd66a9f4f3efa/initrd
```

`03-extract-boot.sh` finds the root partition by its GPT type (root-arm64)
with `sfdisk`, mounts it read-only with `sudo mount -o ro,loop,offset=...`
(with `nodev,nosuid,noexec`: the image comes from the Internet), and reads
every entry:

- the profile is the subvolume of `rootflags=subvol=@<Profile>`;
- the paths are relative to the top of the btrfs file system;
- it keeps the entries whose kernel configuration
  (`/@<Profile>/usr/lib/modules/<version>/config`) enables the virtio-mmio
  transport and the virtio block driver, and among them the newest kernel.
  Each image ships two kernels: a mainline kernel (7.3 in build 2407) and
  Rockchip's 6.1 kernel, which has no virtio support (nor btrfs) and is
  always skipped;
- it copies the kernel and the initrd, refusing any path that leads outside
  the image, and keeps the `options` line as the kernel command line, without
  `quiet`. The device-tree lines (`devicetreedir`, `devicetree-overlay`) are
  ignored: they name RK3576 device trees, while QEMU provides its own.

Nothing selects the kernel by version number, and nothing about the disk
layout is hard-coded, so new builds work as long as their kernel keeps
virtio support.

### The virtio-mmio constraint

The FlipperOS kernel is configured for the RK3576 only. It has the virtio
drivers (as modules, in the initrd), but no driver for QEMU's PCI host bridge
(`PCI_HOST_GENERIC`), its PL011 serial port, its PL031 clock, or a virtio
GPU. So every device uses virtio over MMIO: `-device virtio-blk-device`,
`virtio-net-device`, `virtio-rng-device`, `virtio-serial-device`, never the
`-pci` variants. The QEMU command line is built in one place,
`set_qemu_args` in `scripts/lib.sh`, shared by the interactive runner and the
smoke test.

### The console

Without a PL011 driver there is no `ttyAMA0`. The console is a virtio
console, `hvc0`, appended to the kernel command line. Its driver is a module
that is not in the initrd, so it only appears once the root file system is
mounted, about 20 seconds after the start. From then on the console shows the
systemd messages, then a login prompt (started explicitly with
`systemd.wants=serial-getty@hvc0.service`). The early kernel messages are not
lost: read them with `dmesg` in the guest.

The console and the QEMU monitor share the terminal: `Ctrl-a c` switches
between them, `Ctrl-a x` quits, `Ctrl-a h` lists the keys. Each run is also
written to `work/<BUILD_ID>/logs/`.

### Networking

QEMU's user-mode network needs no root and no setup on the host. The guest
gets the address 10.0.2.15 by DHCP and reaches the Internet through the host,
but the host and the network can only reach it through forwarded ports:

```text
host 127.0.0.1:8899  ──>  guest 10.0.2.15:8899   FlipCTL remote view
host 127.0.0.1:2222  ──>  guest 10.0.2.15:22     SSH
```

The smoke test uses other host ports (18899 and 12222), so it can run next to
a VM started with `05-run.sh`. It also boots on a throwaway overlay of the
image, never on your VM disk.

## Limitations and troubleshooting

### The console stays silent at the start

Normal: the virtio console driver is loaded with the root file system, about
20 seconds after the start (see [the console](#the-console)). FlipCTL and SSH
answer after about 30 seconds. If nothing at all shows after two minutes,
the boot stopped before the root file system was mounted, and its messages
cannot reach this console (see [going further](#going-further-untested) for
a kernel with a serial console). Check that `./scripts/03-extract-boot.sh`
found a kernel with virtio support for this profile.

### "port 8899 is already in use"

Another VM, or another program, uses the port. Stop it. To run a second VM
at the same time, it must be of another build (each build has one VM disk,
which only one VM can use), on other ports:
`FLIPCTL_PORT=8898 SSH_PORT=2223 ./scripts/05-run.sh 2405`.

### The mount fails, or sudo is refused

- `mount: ... unknown filesystem type 'btrfs'` or a loop device error: the
  host kernel lacks the driver. This happens after a kernel upgrade without a
  reboot (the modules of the running kernel are gone): reboot.
  `./scripts/00-check-host.sh` detects it.
- No sudo rights: see [mounting without sudo](#mounting-without-sudo).

### Mounting without sudo

`03-extract-boot.sh` only needs to read the root partition. If you can mount
it another way, for example with udisks, which lets desktop users mount
without a password, run the steps one by one instead of `setup.sh`:

```sh
./scripts/02-download.sh 2407
udisksctl loop-setup --read-only --file work/2407/image.img --offset 67108864 --size 6374293504
udisksctl mount --block-device /dev/loop0 --options ro
ROOT_MOUNT=/run/media/$USER/flipperos ./scripts/03-extract-boot.sh 2407
udisksctl unmount --block-device /dev/loop0
udisksctl loop-delete --block-device /dev/loop0
./scripts/04-create-disk.sh 2407
```

`03-extract-boot.sh` prints the offset and size of the partition. Use the
loop device and the mount point that `udisksctl` prints (Debian and Ubuntu
mount under `/media/$USER/` instead of `/run/media/$USER/`).

### "no kernel of build ... can boot under QEMU"

This build's kernels do not have `CONFIG_VIRTIO_MMIO` and `CONFIG_VIRTIO_BLK`
(as `y` or `m`). These scripts cannot boot it; try another build, or rebuild
the kernel (see [going further](#going-further-untested)).

### It is slow

Everything is emulated. On an Intel Core Ultra 5 125U laptop, FlipCTL and
SSH answer about 30 seconds after the start (a little less on the next boots
of the same VM disk). More CPUs do not help: `CPUS=8` is not faster than the
default 4. With QEMU 11, `CPU_MODEL=max` is faster (about 25 seconds), at the
price of a CPU that differs more from the RK3576.

### Desktop and TV-Media-Box show nothing

These profiles start a graphical session, but the kernel has no driver for
any display QEMU can emulate (no virtio GPU, no simple framebuffer), so there
is nothing to show. They boot, and FlipCTL and SSH work.

### Kernel updates made inside the VM are not used

QEMU boots the kernel extracted from the downloaded image, not the one in the
VM disk. If you update the kernel inside the VM (with `apt` or
`update-profile`), the guest keeps booting the old kernel, whose modules may
then be missing. Prefer a new build: `./scripts/setup.sh latest`.

### The guest clock

QEMU has a real-time clock, but the FlipperOS kernel has no driver for it.
The guest starts with a date stored in the image, then `systemd-timesyncd`
sets the clock from NTP (Debian pool) about 30 seconds after the start, once
the network is up. Until then HTTPS may fail ("the app catalogue did not
answer" in FlipCTL's App Manager). Without Internet access the clock stays
wrong. `06-smoke-test.sh` reports it.

### Failed units at the start are expected

Under QEMU these units fail, harmlessly:

- `usb-ncm-msc-mtp-gadget.service`: there is no USB device controller;
- `set-hostname-and-banner.service`: it names the machine after the serial
  number of the board (from the device tree or the RK3576 OTP memory) or,
  failing that, after `/etc/machine-id`. QEMU's machine has no such serial
  number, and the machine ID is missing too: the boot entries mount the root
  file system read-only at first, so systemd cannot create `/etc/machine-id`
  on the first boot. The hostname stays `debian-rk3576` and the SSH banner
  keeps its short version;
- `systemd-boot-check-no-failures.service`, because of the two above, and so
  `boot-complete.target` and the service that marks the boot entry as good.

Anything that needs the Flipper One hardware (display, buttons, MCU, radios,
GPIO) is absent too.

### Router has no network

The `Router` profile only configures the board's ports: its WAN connection is
tied to the interface `end0`, and it never configures other cards
automatically. The VM's network card is `eth0`, so it gets no address and the
forwarded ports lead nowhere. Log in on the console (`user` / `user`) and
connect it once:

```sh
sudo nmcli device connect eth0
```

NetworkManager saves this connection in the profile, so the next boots of the
same VM disk have the network directly. The router services that need Wi-Fi
or the second Ethernet port fail, as expected.

### FlipCTL's boot menu shows no profiles

FlipCTL's boot menu says "(no profiles)": its service may only open SD, MMC
and NVMe disks, not the virtio disk of the VM, so its profile tools cannot
read the disk ("list-profiles answered nothing for /dev/vda3" in `dmesg`).
Switching profiles from it could not work anyway: no bootloader reads its
choice under QEMU. Choose the profile with `PROFILE=` instead. The profile
tools themselves work over SSH, for example `sudo list-profiles`.

### The terminal is broken after QEMU crashed

If QEMU was killed, the terminal may stay in raw mode: type `reset`.

## Going further (untested)

The kernel limits what QEMU can offer. Rebuilding the mainline kernel with a
few more options would give a serial console from the first instruction, a
real-time clock, PCI devices, and a display for the Desktop profile. The
[build scripts](https://github.com/flipperdevices/flipperone-linux-build-scripts)
merge every fragment of `configs/linux/` into the kernel configuration, so a
file such as `configs/linux/qemu.config` would do:

```text
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
CONFIG_PCI_HOST_GENERIC=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_DRM_VIRTIO_GPU=m
CONFIG_VIRTIO_INPUT=m
CONFIG_RTC_DRV_PL031=y
```

With such a kernel, `console=ttyAMA0` shows the kernel messages from the very
start, and `-device virtio-gpu-pci` with `-display gtk` would give the Desktop
profile a screen. This has not been tried: it is a lead, not a recipe.

## Links and credits

- Flipper One documentation: [Run your own Flipper One](https://docs.flipper.net/one/dev-log/10),
  [FlipperOS](https://docs.flipper.net/one/cpu-software/flipper-os),
  [profiles](https://docs.flipper.net/one/cpu-software/profiles),
  [build system](https://docs.flipper.net/one/cpu-software/build-system).
- Source code by Flipper Devices:
  [image build scripts](https://github.com/flipperdevices/flipperone-linux-build-scripts),
  [FlipCTL](https://github.com/flipperdevices/flipctl-slint),
  [profile tools](https://github.com/flipperdevices/flipperos-btrfs-tools),
  [kernel](https://github.com/flipperdevices/flipper-linux-kernel).
- Builds: <https://dl-linux-images.flipp.dev/full-img/> and
  <https://linux-images.flipp.dev/>.
- [QEMU](https://www.qemu.org/docs/master/system/arm/virt.html) `virt` machine.

FlipperOS is made by Flipper Devices; this repository only contains scripts
to run it.

## License

[MIT](LICENSE), Copyright (c) 2026 Gélules
