#!/bin/bash
#
# 00-check-host.sh - check that this computer can prepare and run Flipper OS.
#
# Usage:
#   ./scripts/00-check-host.sh
#   ./scripts/00-check-host.sh --help     print this help
#
# Inputs:
#   None. Looks for the required programs, the free disk space in WORK_DIR,
#   the RAM, and the host kernel drivers needed to mount the image.
#
# Outputs:
#   A report on the terminal, with the install command for your distribution
#   when something is missing. Exit status 1 if a required program is missing.
#
# Environment:
#   WORK_DIR, MEMORY (see config.env).

# Load the shared helpers and the configuration.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh" || exit 1

# Read the command line.
case "$1" in
    -h | --help)
        show_help
        exit 0
        ;;
esac

# Programs the scripts cannot work without.
required="curl zstd sha256sum sfdisk mount umount qemu-system-aarch64 qemu-img"

# sudo is only needed when we are not root (to mount the disk image).
if [ "$(id --user)" -ne 0 ]; then
    required="$required sudo"
fi

# Look for each required program and remember the missing ones.
missing=""
for program in $required; do
    if command -v "$program" >/dev/null 2>&1; then
        info "found    $program"
    else
        info "MISSING  $program"
        missing="$missing $program"
    fi
done

# sshpass is optional: the smoke test uses it to log into the guest, and
# skips the in-guest checks without it.
if command -v sshpass >/dev/null 2>&1; then
    info "found    sshpass (optional)"
else
    warn "sshpass not found: 06-smoke-test.sh will skip the checks made inside the guest."
fi

# When something is missing, print the install command for this distribution,
# guessed from the ID and ID_LIKE fields of /etc/os-release
# (for example "ID=ubuntu" and "ID_LIKE=debian").
if [ -n "$missing" ]; then
    distro=$(sed --quiet 's/^ID\(_LIKE\)\{0,1\}=//p' /etc/os-release 2>/dev/null | tr --delete '"' | tr '\n' ' ')
    case " $distro " in
        *" arch "*)
            hint="sudo pacman -S --needed curl zstd coreutils util-linux qemu-system-aarch64 qemu-img sshpass sudo"
            ;;
        *" debian "* | *" ubuntu "*)
            hint="sudo apt install curl zstd coreutils fdisk mount qemu-system-arm qemu-utils sshpass sudo"
            ;;
        *" fedora "*)
            hint="sudo dnf install curl zstd coreutils util-linux qemu-system-aarch64-core qemu-img sshpass sudo"
            ;;
        *)
            hint="install: curl, zstd, coreutils, util-linux (sfdisk, mount), qemu-system-aarch64, qemu-img, sshpass, sudo"
            ;;
    esac
    echo
    warn "missing programs:$missing"
    echo "To install them:"
    echo "    $hint"
    exit 1
fi

# From here on, problems are only warnings: a build that is already prepared
# can still run. Count them for the final message.
warnings=0

# Mounting the image needs the loop device and btrfs drivers of the host
# kernel: built in, already loaded, or available as modules. After a kernel
# upgrade without a reboot, the modules of the running kernel are often gone.
for module in loop btrfs; do
    if [ -d "/sys/module/$module" ] || modinfo "$module" >/dev/null 2>&1; then
        info "found    $module driver in the host kernel"
    else
        warn "no $module driver for the running kernel $(uname --kernel-release): mounting the image will fail."
        warn "If you just upgraded the kernel, reboot."
        warnings=$((warnings + 1))
    fi
done

# A new build needs about 2 GB for the download and 3.5 GB for the image
# (stored sparse), plus room for the VM disk to grow. Check the free space of
# the file system that holds WORK_DIR, or of its parent if it does not exist.
space_dir="$WORK_DIR"
if [ ! -d "$space_dir" ]; then
    space_dir=$(dirname "$WORK_DIR")
fi
free_gb=$(df --output=avail --block-size=1G "$space_dir" 2>/dev/null | tail --lines=1 | tr --delete ' ')
if [ -z "$free_gb" ]; then
    warn "could not read the free space of $space_dir"
    warnings=$((warnings + 1))
elif [ "$free_gb" -lt 10 ]; then
    warn "only ${free_gb} GB free in $space_dir; a new build needs about 10 GB."
    warnings=$((warnings + 1))
else
    info "found    ${free_gb} GB free in $space_dir"
fi

# The guest gets MEMORY of RAM. Compare it with the memory available now.
# QEMU reads a plain number as MiB and accepts "4g" as well as "4G": convert
# the value to the form numfmt understands ("4096M", "4G") first.
memory=${MEMORY^^}
case "$memory" in
    *[0-9])
        memory="${memory}M"
        ;;
esac
need_bytes=$(numfmt --from=iec "$memory" 2>/dev/null)
available_kb=$(awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo)
if [ -z "$need_bytes" ]; then
    warn "cannot read MEMORY=$MEMORY (use a size such as 4G)"
    warnings=$((warnings + 1))
elif [ "$available_kb" -lt $((need_bytes / 1024)) ]; then
    warn "the VM wants MEMORY=$MEMORY but only $((available_kb / 1024)) MB are available; lower MEMORY or close programs."
    warnings=$((warnings + 1))
else
    info "found    $((available_kb / 1024)) MB of available RAM (the VM uses $MEMORY)"
fi

echo
if [ "$warnings" -eq 0 ]; then
    info "The host is ready."
else
    info "The host has the required programs, but read the $warnings warning(s) above."
fi
info "Next: ./scripts/01-list-builds.sh  (or directly: ./scripts/setup.sh latest)"
