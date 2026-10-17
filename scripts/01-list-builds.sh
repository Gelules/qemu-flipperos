#!/bin/bash
#
# 01-list-builds.sh - list the FlipperOS builds published on the build server.
#
# Usage:
#   ./scripts/01-list-builds.sh             list every build, newest first
#   ./scripts/01-list-builds.sh BUILD_ID    list the files of one build
#   ./scripts/01-list-builds.sh latest      same, for the newest build without a label
#   ./scripts/01-list-builds.sh --help      print this help
#
# Inputs:
#   BUILD_ID   optional build ID, for example 2407 or 2410-test-falcon.
#
# Outputs:
#   The list on the terminal. Nothing is written to disk.
#
# Environment:
#   BASE_URL, IMAGE_VARIANTS (see config.env).

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
build_id="$1"

# --- Without argument: list the builds --------------------------------------

if [ -z "$build_id" ]; then
    # Read the build list once: it comes from the server's manifest.json.
    info "Reading $BASE_URL/manifest.json"
    builds=$(list_server_builds)
    if [ -z "$builds" ]; then
        die "could not read the build list from $BASE_URL/manifest.json"
    fi

    # One line per build. A label (text after the build number) marks a
    # build of another branch, of a pull request, or a build started by hand.
    printf '%-46s %s\n' "BUILD ID" "PUBLISHED (UTC)"
    echo "$builds" | while read -r id date; do
        number=${id%%-*}
        if [ "$number" = "$id" ]; then
            note=""
        else
            note="label: ${id#*-}"
        fi
        # Keep the date to the minute: 2026-10-17T07:42 becomes 2026-10-17 07:42.
        date=${date:0:16}
        printf '%-46s %-17s %s\n' "$id" "${date/T/ }" "$note"
    done

    # Summary, printed last so that it stays visible on the terminal.
    count=$(echo "$builds" | wc --lines)
    newest=$(echo "$builds" | head --lines=1 | cut --delimiter=' ' --fields=1)
    latest=$(echo "$builds" | awk '$1 ~ /^[0-9]+$/ { print $1; exit }')
    echo
    info "$count builds. Newest: $newest. Newest without a label (\"latest\"): $latest."
    info "Next: ./scripts/01-list-builds.sh $latest   (files of that build)"
    info "  or: ./scripts/setup.sh $latest"
    exit 0
fi

# --- With a build ID: list its files ----------------------------------------

# "latest" means the newest build without a label.
if [ "$build_id" = "latest" ]; then
    build_id=$(latest_build_id)
    if [ -z "$build_id" ]; then
        die "could not find the latest build on $BASE_URL"
    fi
    info "latest = $build_id"
fi

# Every build directory has its own manifest.json with the file list.
info "Reading $BASE_URL/$build_id/manifest.json"
files=$(list_build_files "$build_id")
if [ -z "$files" ]; then
    die "no file list for build $build_id (check the ID with ./scripts/01-list-builds.sh)"
fi

# The file 02-download.sh would take (first of IMAGE_VARIANTS found).
chosen=$(echo "$files" | pick_image_file)

# One line per file, with a human-readable size.
printf '%-52s %8s\n' "FILE" "SIZE"
echo "$files" | while read -r name size sha256; do
    if [ "$name" = "$chosen" ]; then
        mark="<- used by 02-download.sh"
    else
        mark=""
    fi
    printf '%-52s %8s  %s\n' "$name" "$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null)" "$mark"
done

# Where the build comes from: the Buildbot page and the source revisions,
# also read from the manifest. A label usually matches a branch name here.
manifest=$(manifest_objects "$BASE_URL/$build_id/manifest.json")
echo
echo "Build details: $(echo "$manifest" | json_value url | head --lines=1)"
echo "Sources:"
echo "$manifest" | grep '"codebase"' | while read -r object; do
    printf '    %-16s %-24s %.12s\n' \
        "$(echo "$object" | json_value codebase)" \
        "$(echo "$object" | json_value branch)" \
        "$(echo "$object" | json_value revision)"
done

# Tell what to do next.
echo
if [ -n "$chosen" ]; then
    info "Next: ./scripts/setup.sh $build_id"
else
    die "no image of the variants \"$IMAGE_VARIANTS\" in build $build_id"
fi
