#!/bin/bash
#
# 03-extract-boot.sh - copy the kernel, initrd and kernel command line of
# every Flipper OS profile out of the disk image.
#
# On the real hardware, U-Boot reads the Boot Loader Specification (BLS)
# entries in /boot/loader/entries of the btrfs root file system: one entry per
# profile and per kernel. QEMU has no U-Boot here, so this script reads the
# same entries and keeps, for each profile, what QEMU needs to boot it.
#
# Usage:
#   ./scripts/03-extract-boot.sh [--force] [BUILD_ID]
#   ./scripts/03-extract-boot.sh --help
#
# Inputs:
#   BUILD_ID   prepared build (default: the build set up last, work/current).
#   --force    extract again even if the boot files are already there.
#   work/<BUILD_ID>/image.img, from 02-download.sh.
#
# Outputs, in work/<BUILD_ID>/:
#   boot/<Profile>/vmlinuz          kernel (gzip-compressed arm64 Image)
#   boot/<Profile>/initrd           initramfs, with the virtio modules
#   boot/<Profile>/cmdline          "options" of the boot entry, without "quiet"
#   boot/<Profile>/kernel-version   kernel version ("uname -r" in the guest)
#   boot/<Profile>/entry.conf       the boot entry all this comes from
#   boot/<Profile>/os-release       /etc/os-release of the profile
#   build-info.txt                  completed with the file system details
#
# Environment:
#   WORK_DIR (see config.env).
#   ROOT_MOUNT  optional: directory where the root partition of this image
#               is already mounted (by you, a file manager...). The script
#               then reads from it and does not mount anything itself.
#
# Root access: the root partition is mounted read-only with
# "sudo mount -o ro,nodev,nosuid,noexec,loop,offset=...,sizelimit=...", and
# unmounted at the end, also after an error or Ctrl-C.

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
if [ ! -e "$image" ]; then
    die "$image not found. Run ./scripts/02-download.sh $build_id first."
fi

# boot/ only appears once every profile was extracted (it is built as
# boot.tmp/ and renamed at the end), so when it exists the work is done.
if [ -d "$dir/boot" ] && [ "$force" = no ]; then
    info "$dir/boot is already there (use --force to extract again)."
    info "Profiles: $(build_info "$dir" profiles)"
    info "Next: ./scripts/04-create-disk.sh $build_id"
    exit 0
fi
rm --recursive --force "$dir/boot.tmp"

# --- Helpers ----------------------------------------------------------------

# Print the value of a key of a BLS entry file: "linux  /path" gives "/path".
entry_value() {
    awk -v key="$1" '$1 == key { $1 = ""; sub(/^ +/, ""); print; exit }' "$2"
}

# Copy a file out of the mounted image, so that the current user owns the
# copy. The path comes from the image, which is downloaded from the Internet:
# once ".." and symbolic links are resolved, it must still lead to a regular
# file inside the mounted file system. Otherwise a crafted image could make
# sudo read a file of this computer. The resolved path must not be a link
# itself: $( ... ) drops the newlines that end a name, so a link named after
# a strange target could hide there. Files only root can read are read
# through sudo, unless the image was mounted by the user (ROOT_MOUNT).
copy_out() {
    local real

    real=$(readlink --canonicalize-existing "$1")
    case "$real" in
        "$mnt_real"/*)
            ;;
        *)
            echo "[$PROG] ERROR: $1 does not exist, or leads outside the image." >&2
            return 1
            ;;
    esac
    if [ -L "$real" ] || [ ! -f "$real" ]; then
        echo "[$PROG] ERROR: $1 is not a regular file." >&2
        return 1
    fi

    if [ -r "$real" ]; then
        cp "$real" "$2"
    elif [ -z "$ROOT_MOUNT" ]; then
        as_root cat "$real" > "$2"
    else
        echo "[$PROG] ERROR: $1 is not readable by $(id --user --name) ($(stat --format='%U:%G mode %a' "$real"))." >&2
        echo "[$PROG] ERROR: unset ROOT_MOUNT to let the script mount the image with sudo." >&2
        return 1
    fi
}

# Unmount the image when the script ends, whatever the reason. Writing a
# message to a closed pipe (output sent to "tee", then Ctrl-C) must not stop
# the clean-up, hence "trap '' PIPE".
mnt=""
cleanup() {
    trap '' PIPE
    if [ -z "$ROOT_MOUNT" ] && [ -n "$mnt" ] && mountpoint --quiet "$mnt"; then
        info "Unmounting $mnt"
        as_root umount "$mnt" || warn "could not unmount $mnt, run: sudo umount $mnt"
    fi
    if [ -z "$ROOT_MOUNT" ] && [ -n "$mnt" ]; then
        rmdir "$mnt" 2>/dev/null
    fi
    rm --recursive --force "$dir/boot.tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Mount the root partition -----------------------------------------------

# Find the root partition in the GPT of the image, by type or name, and check
# that sfdisk gave plain numbers before computing with them.
read -r start size sector <<< "$(root_partition "$image")"
case "$start$size$sector" in
    "" | *[!0-9]*)
        die "no root partition (GPT type root-arm64 or name \"root\") in $image"
        ;;
esac
offset=$((start * sector))
length=$((size * sector))
info "Root partition: offset $offset, size $length bytes"

if [ -n "$ROOT_MOUNT" ]; then
    # The user mounted it already.
    mnt="$ROOT_MOUNT"
    info "Using the root file system mounted on $mnt (ROOT_MOUNT)"
else
    # Mount it read-only through a loop device limited to the partition. The
    # image is not trusted: only the btrfs driver may read it, and device
    # files and programs on it are disabled (nodev, nosuid, noexec). The loop
    # device is released by umount.
    mnt="$dir/mnt"
    mkdir --parents "$mnt" || die "cannot create $mnt"
    info "Mounting the root partition on $mnt (needs sudo)"
    if ! as_root mount --types btrfs --options "ro,nodev,nosuid,noexec,loop,offset=$offset,sizelimit=$length" "$image" "$mnt"; then
        die "mount failed (is the btrfs driver of the host kernel available? see ./scripts/00-check-host.sh)"
    fi
fi

# The canonical path of the mount point, used by copy_out to check paths.
mnt_real=$(readlink --canonicalize-existing "$mnt") || die "cannot resolve $mnt"

# The btrfs default subvolume is the top level, so the mount shows the boot
# subvolume ("boot", mounted on /boot by every profile) and the profiles
# (@Minimal, @Desktop...) side by side.
entries_dir="$mnt/boot/loader/entries"
if ! ls "$entries_dir"/*.conf >/dev/null 2>&1; then
    die "no boot entry in $entries_dir"
fi

# --- Choose one boot entry per profile --------------------------------------

# Look at every entry. Each one names a kernel, an initrd and the kernel
# command line, which selects the profile with rootflags=subvol=@<Profile>.
# Keep the entries whose kernel can boot under QEMU: it needs an initrd (the
# virtio drivers are modules), the virtio-mmio transport and the virtio block
# driver (built in or as modules). On current images this keeps the mainline
# kernel and drops Rockchip's BSP kernel.
candidates=""
all_profiles=""
for entry in "$entries_dir"/*.conf; do
    # Only regular files: a FIFO, for example, would block the reading.
    if [ ! -f "$entry" ]; then
        warn "$(basename "$entry"): not a regular file, skipped"
        continue
    fi
    version=$(entry_value version "$entry")
    options=$(entry_value options "$entry")
    linux=$(entry_value linux "$entry")
    initrd=$(entry_value initrd "$entry")

    # The profile is the root subvolume: "subvol=@Minimal" gives "Minimal".
    subvol=$(echo "$options" | grep --only-matching 'subvol=[^ ,]*' | head --lines=1)
    subvol=${subvol#subvol=}
    subvol=${subvol#/}
    profile=${subvol#@}
    if [ -z "$profile" ] || [ -z "$linux" ]; then
        warn "$(basename "$entry"): no root subvolume or no kernel, skipped"
        continue
    fi

    # The profile name becomes a directory name: accept only the characters
    # Flipper OS allows in profile names.
    case "$profile" in
        .* | *[!A-Za-z0-9._-]*)
            warn "$(basename "$entry"): invalid profile name \"$profile\", skipped"
            continue
            ;;
    esac
    all_profiles="$all_profiles $profile"

    # Without an initrd the virtio modules cannot be loaded before the root
    # file system is mounted.
    if [ -z "$initrd" ]; then
        info "$(basename "$entry"): no initrd, skipped"
        continue
    fi

    # The kernel configuration sits next to the kernel modules, or in /boot
    # for kernels installed the old way.
    config="$mnt/$subvol/usr/lib/modules/$version/config"
    if [ ! -f "$config" ]; then
        config="$mnt/boot/config-$version"
    fi
    if [ ! -f "$config" ] || [ ! -r "$config" ]; then
        warn "$(basename "$entry"): kernel configuration not found or not readable, skipped"
        continue
    fi

    if grep --quiet --extended-regexp '^CONFIG_VIRTIO_MMIO=(y|m)$' "$config" &&
        grep --quiet --extended-regexp '^CONFIG_VIRTIO_BLK=(y|m)$' "$config"; then
        info "$(basename "$entry"): kernel $version has virtio-mmio, usable"
        candidates="$candidates$profile $version $entry
"
    else
        info "$(basename "$entry"): kernel $version has no virtio-mmio or virtio-blk, skipped"
    fi
done

# For each profile, keep the usable entry with the newest kernel version.
selected=$(printf '%s' "$candidates" | sort --key=1,1 --key=2,2Vr | awk '!seen[$1]++')
if [ -z "$selected" ]; then
    die "no kernel of build $build_id can boot under QEMU: none has an initrd and CONFIG_VIRTIO_MMIO and CONFIG_VIRTIO_BLK set to y or m (see the lines above). This build cannot run with these scripts."
fi

# Report the profiles that have no usable kernel at all.
for profile in $(echo "$all_profiles" | tr ' ' '\n' | sort --unique); do
    if ! echo "$selected" | grep --quiet "^$profile "; then
        warn "profile $profile has no usable kernel (virtio support and an initrd), skipped"
    fi
done

# --- Copy the boot files ----------------------------------------------------

# One line of $selected per profile: "<profile> <kernel version> <entry>".
profiles=""
while read -r profile version entry; do
    linux=$(entry_value linux "$entry")
    initrd=$(entry_value initrd "$entry")
    options=$(entry_value options "$entry")
    out="$dir/boot.tmp/$profile"
    info "$profile: kernel $version"

    # Copy the kernel and the initrd. Paths in BLS entries are relative to
    # the btrfs top level, for example /@Minimal/usr/lib/modules/<ver>/vmlinuz.
    mkdir --parents "$out" || die "cannot create $out"
    copy_out "$mnt$linux" "$out/vmlinuz" || die "cannot copy $linux"
    copy_out "$mnt$initrd" "$out/initrd" || die "cannot copy $initrd"

    # Keep the kernel command line of the entry. "quiet" is dropped so that
    # the boot messages show on the console.
    read -r -a words <<< "$options"
    cmdline=""
    for word in "${words[@]}"; do
        if [ "$word" != "quiet" ]; then
            cmdline="$cmdline $word"
        fi
    done
    echo "${cmdline# }" > "$out/cmdline"

    # Keep the kernel version, the entry itself, and the profile's
    # os-release (the smoke test compares it with the running guest).
    echo "$version" > "$out/kernel-version"
    cp "$entry" "$out/entry.conf"
    subvol=$(echo "$options" | grep --only-matching 'subvol=[^ ,]*' | head --lines=1)
    subvol=${subvol#subvol=}
    copy_out "$mnt/${subvol#/}/etc/os-release" "$out/os-release" || die "cannot copy os-release"

    profiles="$profiles $profile"
done <<< "$selected"

profiles=${profiles# }
if [ -z "$profiles" ]; then
    die "no profile could be extracted"
fi

# --- Record what was found --------------------------------------------------

# File system UUID and label, read from the image itself.
fs_uuid=$(blkid --probe --offset "$offset" --output value --match-tag UUID "$image")
fs_label=$(blkid --probe --offset "$offset" --output value --match-tag LABEL "$image")

# BUILD_ID of /etc/os-release is the number of the root file system build,
# which differs from the number of the disk image build.
first=${profiles%% *}
os_build_id=$(sed --quiet 's/^BUILD_ID=//p' "$dir/boot.tmp/$first/os-release" | tr --delete '"')
os_build_git=$(sed --quiet 's/^BUILD_GIT=//p' "$dir/boot.tmp/$first/os-release" | tr --delete '"')

# Rewrite build-info.txt: keep what 02-download.sh wrote, add the rest.
{
    grep --extended-regexp '^(#|build_id=|source_|downloaded_at=)' "$dir/build-info.txt" 2>/dev/null
    echo "fs_uuid=$fs_uuid"
    echo "fs_label=$fs_label"
    echo "os_build_id=$os_build_id"
    echo "os_build_git=$os_build_git"
    echo "profiles=$profiles"
    for profile in $profiles; do
        echo "kernel_$profile=$(cat "$dir/boot.tmp/$profile/kernel-version")"
    done
    echo "extracted_at=$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
} > "$dir/build-info.txt.new"
mv "$dir/build-info.txt.new" "$dir/build-info.txt"

# Everything is there: give boot/ its final name (cleanup then unmounts).
# ${dir:?} stops the script if dir were empty: this never deletes /boot.
rm --recursive --force "${dir:?}/boot"
mv "$dir/boot.tmp" "$dir/boot" || die "cannot rename $dir/boot.tmp"

info "Profiles: $profiles"
info "Root file system: label $fs_label, UUID $fs_uuid, os-release BUILD_ID $os_build_id"
info "Next: ./scripts/04-create-disk.sh $build_id"
