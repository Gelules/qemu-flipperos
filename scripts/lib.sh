#!/bin/bash
#
# lib.sh - helpers shared by all the qemu-flipperos scripts.
#
# Usage:
#   This file is sourced by the other scripts, it is not meant to be run:
#       . "$(dirname "$0")/lib.sh" || exit 1
#
# Inputs:
#   config.env at the top of the repository, and the environment variables
#   that override it.
#
# Outputs:
#   Variables: SCRIPTS_DIR, TOP_DIR, PROG, every setting of config.env, and
#   QEMU_ARGS once set_qemu_args has been called.
#   Functions: messages (info, warn, die, show_help), root access (as_root),
#   build server access, build directories, partition lookup and the QEMU
#   command line shared by 05-run.sh and 06-smoke-test.sh.
#
# Environment:
#   See config.env.

# --- Paths and configuration ------------------------------------------------

# Absolute paths of the scripts directory and of the repository, so that the
# scripts work whatever the current directory is.
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOP_DIR=$(dirname "$SCRIPTS_DIR")

# Read the default settings. Values already set in the environment win.
# shellcheck source=../config.env
. "$TOP_DIR/config.env" || exit 1

# Some distributions (Debian) keep sfdisk, blkid and modinfo in /usr/sbin,
# which is not in the PATH of a normal user.
PATH="$PATH:/usr/sbin:/sbin"

# Name of the running script without ".sh", shown in front of every message.
PROG=$(basename "$0" .sh)

# --- Messages ---------------------------------------------------------------

# Print a progress message.
info() {
    echo "[$PROG] $*"
}

# Print a warning on the error output.
warn() {
    echo "[$PROG] WARNING: $*" >&2
}

# Print an error on the error output and stop the script.
# Note: inside $( ... ) this only leaves the sub-shell, so callers of
# functions used that way check the exit status themselves.
die() {
    echo "[$PROG] ERROR: $*" >&2
    exit 1
}

# Print the documentation of the running script: its header comment, from
# line 3 to the first empty line, without the leading "# ".
show_help() {
    sed --quiet '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# --- Root access ------------------------------------------------------------

# Run a command as root: directly if we already are root, else with sudo.
# Only mounting the disk image and copying files out of it need this.
as_root() {
    if [ "$(id --user)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# --- Build server -----------------------------------------------------------

# Download a URL and print it on the standard output.
http_get() {
    curl --silent --show-error --fail --location "$1"
}

# Print every object of a manifest.json, one per line.
# The build server describes each directory with a small manifest.json (the
# HTML listing is drawn from it by JavaScript). To avoid depending on a JSON
# parser, the whole document is put on one line and cut at the braces: the
# objects we need (builds and files) contain no nested object.
# The document is downloaded completely first, so that a failed download
# gives nothing instead of part of the list.
manifest_objects() {
    local json

    json=$(http_get "$1") || return 1
    echo "$json" | tr --delete '\n' | grep --only-matching '{[^{}]*}'
}

# Print the value of a field of the one-line JSON object read on stdin.
# Works for strings ("name": "2407/") and numbers ("size": 3849).
json_value() {
    sed --quiet "s/.*\"$1\": *\"\{0,1\}\([^\",}]*\).*/\1/p"
}

# Print the builds published on the server, newest first, one per line:
#   <build ID> <publication date>
# A build ID is a build number, optionally followed by a label, for example
# "2407" or "2410-test-falcon".
list_server_builds() {
    local object name date

    manifest_objects "$BASE_URL/manifest.json" | while read -r object; do
        # Directory entries look like {"name": "2407/", "mtime": "..."}.
        name=$(echo "$object" | json_value name)
        date=$(echo "$object" | json_value mtime)
        if [ -n "$name" ]; then
            echo "${name%/} ${date%%.*}"
        fi
    done | sort --numeric-sort --reverse
}

# Print the newest build ID without a label. A label marks a build made from
# another branch, a pull request or by hand, so unlabelled builds are the
# regular ones.
latest_build_id() {
    list_server_builds | awk '$1 ~ /^[0-9]+$/ { print $1; exit }'
}

# Print the files of a build, one per line: <file name> <size> <sha256>
list_build_files() {
    local object path size sha256

    manifest_objects "$BASE_URL/$1/manifest.json" | while read -r object; do
        # File entries have a "path"; the other objects (build information,
        # source revisions) do not.
        path=$(echo "$object" | json_value path)
        size=$(echo "$object" | json_value size)
        sha256=$(echo "$object" | json_value sha256)
        if [ -n "$path" ]; then
            echo "$path ${size:-?} ${sha256:-?}"
        fi
    done
}

# Print the name of the disk image to use among the files of a build (read on
# stdin, as printed by list_build_files): the first variant of IMAGE_VARIANTS
# that exists. Only 512-byte-sector images are considered: the "debian-4096"
# images made for UFS storage cannot be read on a virtio disk.
pick_image_file() {
    local files variant name

    files=$(cat)
    for variant in $IMAGE_VARIANTS; do
        name=$(echo "$files" | awk -v prefix="debian-512-$variant-" \
            'index($1, prefix) == 1 && $1 ~ /\.img\.zst$/ { print $1; exit }')
        if [ -n "$name" ]; then
            echo "$name"
            return 0
        fi
    done
    return 1
}

# --- Build directories ------------------------------------------------------

# Print the work directory of a build.
build_dir() {
    echo "$WORK_DIR/$1"
}

# Print the build ID that a script working on a prepared build should use:
# its argument if one was given, else the build work/current points to (the
# build set up last).
local_build_id() {
    if [ "$1" = "latest" ]; then
        echo "[$PROG] ERROR: \"latest\" only works with setup.sh and 02-download.sh; give a build ID, or nothing for the build set up last." >&2
        return 1
    elif [ -n "$1" ]; then
        echo "$1"
    elif [ -L "$WORK_DIR/current" ]; then
        basename "$(readlink "$WORK_DIR/current")"
    else
        echo "[$PROG] ERROR: no build prepared yet, run ./scripts/setup.sh first." >&2
        return 1
    fi
}

# Read a value from the build-info.txt file of a build directory.
build_info() {
    sed --quiet "s/^$2=//p" "$1/build-info.txt" 2>/dev/null | tail --lines=1
}

# Succeed if a running QEMU uses this disk image. QEMU locks the images it
# opens: then qemu-img can only read the image with --force-share.
disk_in_use() {
    ! qemu-img info "$1" >/dev/null 2>&1 &&
        qemu-img info --force-share "$1" >/dev/null 2>&1
}

# --- Disk image -------------------------------------------------------------

# Print "<start> <size> <sector size>" of the root partition of a disk image,
# start and size counted in sectors. The partition is found by its GPT type
# (root-arm64) or, failing that, by its name ("root"); never by a fixed
# offset, so a new partition layout keeps working.
root_partition() {
    sfdisk --dump "$1" | awk '
        # Header line, for example "sector-size: 512".
        $1 == "sector-size:" { sector = $2 }

        # Partition lines look like:
        # image.img3 : start= 131072, size= 12449792, type=B921B045-..., name="root"
        / : start=/ {
            line = $0
            start = line; sub(/.*start= */, "", start); sub(/,.*/, "", start)
            size = line;  sub(/.*size= */, "", size);   sub(/,.*/, "", size)
            if (line ~ /type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE/ && !by_type) {
                by_type = start " " size
            }
            if (line ~ /name="root"/ && !by_name) {
                by_name = start " " size
            }
        }

        END {
            if (!sector) sector = 512
            if (by_type) print by_type, sector
            else if (by_name) print by_name, sector
            else exit 1
        }'
}

# --- Virtual machine --------------------------------------------------------

# Succeed if something already listens on a TCP port of BIND_ADDR.
port_in_use() {
    (echo > "/dev/tcp/$BIND_ADDR/$1") 2>/dev/null
}

# Print the guest kernel command line for a profile boot directory.
# It is the "options" line of the profile's boot entry (saved by
# 03-extract-boot.sh), plus the virtio console. When ROOT_SUBVOL is set, the
# root subvolume is replaced by it.
guest_cmdline() {
    local cmdline subvol

    cmdline=$(cat "$1/cmdline") || return 1

    # Boot another subvolume with this kernel, for example a profile created
    # inside the VM: in "rootflags=subvol=@Minimal", "subvol=@Minimal" is
    # replaced by "subvol=$ROOT_SUBVOL".
    if [ -n "$ROOT_SUBVOL" ]; then
        subvol=$(echo "$cmdline" | grep --only-matching 'subvol=[^ ,]*')
        if [ -z "$subvol" ]; then
            echo "[$PROG] ERROR: no subvol= option in $1/cmdline" >&2
            return 1
        fi
        cmdline=${cmdline/"$subvol"/"subvol=$ROOT_SUBVOL"}
    fi

    # hvc0 is the virtio console. It must come last to become /dev/console.
    # Its device only appears when the virtio_console module is loaded, so
    # systemd is told explicitly to start a login prompt on it.
    echo "$cmdline console=hvc0 systemd.wants=serial-getty@hvc0.service"
}

# Fill the QEMU_ARGS array with the virtual machine shared by 05-run.sh and
# 06-smoke-test.sh, so that both boot exactly the same machine.
#   $1  build directory      $2  profile           $3  disk image (qcow2)
#   $4  host port for FlipCTL                      $5  host port for SSH
# The console options are added by the callers: they differ between an
# interactive run and a headless test.
set_qemu_args() {
    local boot_dir="$1/boot/$2"
    local cmdline

    cmdline=$(guest_cmdline "$boot_dir") || return 1

    # QEMU_ARGS is read by the scripts that source this file.
    # shellcheck disable=SC2034
    QEMU_ARGS=(
        # Generic ARM board of QEMU. There is no RK3576 model, and we do not
        # need one: the mainline arm64 kernel boots on any machine it has
        # drivers for, and virt only needs virtio drivers.
        -machine virt
        -cpu "$CPU_MODEL"
        -smp "$CPUS"
        -m "$MEMORY"

        # Start from an empty machine (no default network card, serial port,
        # monitor or display) and add only what Flipper OS can drive.
        -nodefaults
        -display none

        # Direct kernel boot: QEMU loads the kernel and the initrd taken from
        # the image, so no bootloader (U-Boot, TF-A, DDR blob) is involved.
        -kernel "$boot_dir/vmlinuz"
        -initrd "$boot_dir/initrd"
        -append "$cmdline"

        # The disk. Flipper OS has no virtio-pci host driver, so every virtio
        # device uses the MMIO transport: "-device virtio-*-device", never
        # "virtio-*-pci".
        -drive "if=none,id=disk0,file=$3,format=qcow2"
        -device "virtio-blk-device,drive=disk0"

        # User-mode network (no root needed). The guest gets 10.0.2.15 and
        # Internet access through the host; only the forwarded ports reach it.
        -netdev "user,id=net0,hostfwd=tcp:$BIND_ADDR:$4-:8899,hostfwd=tcp:$BIND_ADDR:$5-:22"
        -device "virtio-net-device,netdev=net0"

        # Entropy for the guest, so first-boot key generation does not stall.
        -device virtio-rng-device

        # Bus for the virtio console (hvc0); the callers attach the console.
        -device virtio-serial-device
    )
}
