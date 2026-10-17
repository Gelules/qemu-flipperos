#!/bin/bash
#
# 02-download.sh - download, verify and decompress a Flipper OS disk image.
#
# Usage:
#   ./scripts/02-download.sh [--force] [BUILD_ID]
#   ./scripts/02-download.sh --help
#
# Inputs:
#   BUILD_ID   build to download: an ID such as 2407 or 2410-test-falcon, or
#              "latest" for the newest build without a label.
#              Default: BUILD_ID from config.env ("latest").
#   --force    download and decompress again even if the image is already
#              there. This also deletes what was made from the old image:
#              the boot files and the VM disk (changes made in the VM are lost).
#
# Outputs, in work/<BUILD_ID>/:
#   image.img        raw disk image (GPT + root file system), read-only
#   build-info.txt   build ID, source file, URL and SHA-256
#
# Environment:
#   BASE_URL, BUILD_ID, IMAGE_VARIANTS, WORK_DIR (see config.env).

# Load the shared helpers and the configuration.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh" || exit 1

# Read the command line.
force=no
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
            BUILD_ID="$1"
            ;;
    esac
    shift
done

# "latest" means the newest build without a label.
build_id="$BUILD_ID"
if [ "$build_id" = "latest" ]; then
    info "Looking for the latest build on $BASE_URL"
    build_id=$(latest_build_id)
    if [ -z "$build_id" ]; then
        die "could not find the latest build on $BASE_URL"
    fi
    info "latest = $build_id"
fi

# The build ID becomes a directory name: refuse anything that could point
# outside the work directory.
case "$build_id" in
    "" | .* | *[!A-Za-z0-9._-]*)
        die "invalid build ID \"$build_id\""
        ;;
esac

dir=$(build_dir "$build_id")
image="$dir/image.img"
disk="$dir/disk.qcow2"

# image.img only appears once a verified archive was fully decompressed, so
# when it exists there is nothing left to do (and no need for the network).
if [ -e "$image" ] && [ "$force" = no ]; then
    info "$image is already there (use --force to download it again)."
    info "Next: ./scripts/03-extract-boot.sh $build_id"
    exit 0
fi

# Pick the image in the build's file list: the first variant of
# IMAGE_VARIANTS that exists ("nobootloader", then a board image).
info "Reading the file list of build $build_id"
files=$(list_build_files "$build_id")
if [ -z "$files" ]; then
    die "no file list for build $build_id (check the ID with ./scripts/01-list-builds.sh; builds older than about 30 days are deleted from the server)"
fi
name=$(echo "$files" | pick_image_file)
if [ -z "$name" ]; then
    echo "Files of build $build_id:" >&2
    echo "$files" | cut --delimiter=' ' --fields=1 | sed 's/^/    /' >&2
    die "no image of the variants \"$IMAGE_VARIANTS\" in build $build_id"
fi

# The file name comes from the server and becomes a path: it must be a plain
# file name.
case "$name" in
    */*)
        die "unexpected file name \"$name\" in the manifest of build $build_id"
        ;;
esac
size=$(echo "$files" | awk -v name="$name" '$1 == name { print $2 }')
sha256=$(echo "$files" | awk -v name="$name" '$1 == name { print $3 }')
url="$BASE_URL/$build_id/$name"
archive="$dir/$name"
info "Image: $name ($(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null))"

# With --force, start again from nothing, now that the build is known to be
# still on the server: delete the image and any archive, complete or partial,
# and what was made from the old image (boot files and VM disk).
if [ "$force" = yes ]; then
    if [ -e "$disk" ] && disk_in_use "$disk"; then
        die "$disk is used by a running VM; stop the VM first"
    fi
    if [ -e "$disk" ]; then
        warn "--force: deleting the VM disk $disk (changes made inside the VM are lost)"
        rm --force "$disk"
    fi
    info "--force: deleting the image, the archives and the boot files in $dir"
    rm --force "$image" "$image.part" "$dir"/*.img.zst "$dir"/*.img.zst.part
    rm --recursive --force "${dir:?}/boot"
fi

# Create the build directory.
mkdir --parents "$dir" || die "cannot create $dir"

# Download to "<name>.part", resuming a previous attempt if there is one.
# The archive only gets its real name once its checksum is verified.
if [ ! -e "$archive" ]; then
    info "Downloading $url"
    if ! curl --fail --location --continue-at - --progress-bar \
        --output "$archive.part" "$url"; then
        die "download failed; run the script again to resume it"
    fi

    # Compare with the SHA-256 published in the build's manifest.json.
    # Old manifests may have no checksum: then let zstd check the archive,
    # zstd frames carry their own checksums.
    if [ "$sha256" != "?" ]; then
        info "Checking the SHA-256 checksum"
        if ! echo "$sha256  $archive.part" | sha256sum --check --status; then
            rm --force "$archive.part"
            die "checksum mismatch for $name; the file was deleted, run the script again"
        fi
    else
        info "No checksum published; testing the archive with zstd"
        if ! zstd --test --quiet "$archive.part"; then
            rm --force "$archive.part"
            die "$name is damaged; the file was deleted, run the script again"
        fi
    fi
    mv "$archive.part" "$archive" || die "cannot rename $archive.part"
fi

# Decompress the disk image. --sparse skips the long runs of zeros, so the
# 6 GiB raw disk only uses the space it really needs (about half). zstd also
# verifies the checksums stored in the archive while it decompresses.
info "Decompressing to $image"
if ! zstd --decompress --sparse --force "$archive" -o "$image.part"; then
    rm --force "$image.part"
    die "decompression failed"
fi

# The raw image is the read-only base of the VM disk: protect it from
# accidental writes, then give it its final name.
chmod a-w "$image.part"
mv "$image.part" "$image" || die "cannot rename $image.part"

# The archive is no longer needed; it can be downloaded again with --force.
rm --force "$archive"

# Remember where the image comes from. 03-extract-boot.sh adds the details
# of the file system to this file.
{
    echo "# Written by 02-download.sh and 03-extract-boot.sh."
    echo "build_id=$build_id"
    echo "source_file=$name"
    echo "source_url=$url"
    echo "source_sha256=$sha256"
    echo "downloaded_at=$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
} > "$dir/build-info.txt"

info "Done: $image ($(du --human-readable "$image" | cut --fields=1) used on disk)"
info "Next: ./scripts/03-extract-boot.sh $build_id"
