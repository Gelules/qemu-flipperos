#!/bin/bash
#
# 04-create-disk.sh - create the writable VM disk, a qcow2 overlay on top of
# the read-only raw image.
#
# The raw image is never modified: the VM reads it through the overlay, and
# every block the VM writes is stored in the overlay. The overlay is bigger
# than the image (DISK_SIZE), and FlipperOS grows its root partition and
# file system to fill it on the first boot.
#
# Usage:
#   ./scripts/04-create-disk.sh [--force] [BUILD_ID]
#   ./scripts/04-create-disk.sh --help
#
# Inputs:
#   BUILD_ID   prepared build (default: the build set up last, work/current).
#   --force    delete the existing VM disk and create a fresh one:
#              everything changed inside the VM is lost. Refused while a VM
#              is running on that disk.
#   work/<BUILD_ID>/image.img, from 02-download.sh.
#
# Outputs:
#   work/<BUILD_ID>/disk.qcow2   the VM disk, backed by image.img
#   work/current                 link to this build, now the build set up last
#
# Environment:
#   DISK_SIZE, WORK_DIR (see config.env).

# Load the shared helpers and the configuration.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh" || exit 1

# Read the command line.
force=no
build_arg=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force)
            force=yes
            ;;
        -h | --help)
            show_help
            exit 0
            ;;
        -*)
            die "unknown option $1 (see --help)"
            ;;
        *)
            build_arg="$1"
            ;;
    esac
    shift
done

# Find the build directory and its disk image.
build_id=$(local_build_id "$build_arg") || exit 1
dir=$(build_dir "$build_id")
image="$dir/image.img"
disk="$dir/disk.qcow2"
if [ ! -e "$image" ]; then
    die "$image not found. Run ./scripts/02-download.sh $build_id first."
fi

# Make work/current point to this build: it becomes the build set up last,
# the one 05-run.sh and 06-smoke-test.sh use without argument. The link is
# relative, so the work directory can be moved.
point_current() {
    ln --symbolic --force --no-dereference "$build_id" "$WORK_DIR/current" ||
        die "cannot update $WORK_DIR/current"
}

# The overlay must not be smaller than the image, or the end of the disk,
# with the end of the root partition and the backup GPT, would vanish.
# qemu-img reads sizes like 16G as binary units, like numfmt --from=iec.
# This is checked first, so that a wrong value never costs the old disk.
disk_bytes=$(numfmt --from=iec "$DISK_SIZE" 2>/dev/null)
image_bytes=$(stat --format=%s "$image")
if [ -z "$disk_bytes" ]; then
    die "invalid DISK_SIZE \"$DISK_SIZE\" (use a size such as 16G)"
fi
if [ "$disk_bytes" -lt "$image_bytes" ]; then
    die "DISK_SIZE=$DISK_SIZE is smaller than the image ($(numfmt --to=iec-i --suffix=B "$image_bytes"))"
fi

# An existing disk holds what was done inside the VM: never replace it
# without --force, never under a running VM, and check that it really is an
# overlay of this image. --force-share reads it even while a VM uses it.
if [ -e "$disk" ]; then
    if disk_in_use "$disk"; then
        if [ "$force" = yes ]; then
            die "$disk is used by a running VM; stop the VM first"
        fi
    elif [ "$force" = yes ]; then
        warn "--force: deleting $disk (changes made inside the VM are lost)"
        rm --force "$disk"
    fi
fi
if [ -e "$disk" ]; then
    details=$(qemu-img info --force-share "$disk") || die "cannot read $disk"
    backing=$(echo "$details" | sed --quiet 's/^backing file: \([^ ]*\).*/\1/p')
    if [ "$backing" != "image.img" ]; then
        die "$disk is not an overlay of image.img (backing file: \"$backing\"). Move it away, or replace it with --force."
    fi
    point_current
    info "$disk is already there (use --force to start again from a fresh disk)."
    info "Next: ./scripts/05-run.sh $build_id"
    exit 0
fi

# Create the overlay. The backing file is given as a path relative to the
# overlay ("image.img"), so the build directory can be moved or renamed.
# -F raw states the backing format, so QEMU never has to guess it.
info "Creating $disk ($DISK_SIZE, backed by image.img)"
if ! qemu-img create -q -f qcow2 -F raw -b image.img "$disk" "$DISK_SIZE"; then
    die "qemu-img create failed"
fi
point_current

info "Done: $(qemu-img info "$disk" | grep '^virtual size')"
info "Next: ./scripts/05-run.sh $build_id"
