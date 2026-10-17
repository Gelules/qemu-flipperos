#!/bin/bash
#
# setup.sh - prepare a FlipperOS build for QEMU in one command: check the
# host, download the image, extract the boot files and create the VM disk.
#
# Usage:
#   ./scripts/setup.sh [--force] [BUILD_ID]
#
# Inputs:
#   BUILD_ID   a build ID such as 2407 or 2410-test-falcon, or "latest" for
#              the newest build without a label.
#              Default: BUILD_ID from config.env ("latest").
#   --force    redo every step, even the ones already done. This also resets
#              the VM disk: everything changed inside the VM is lost.
#
# Outputs:
#   work/<BUILD_ID>/ (see 02-download.sh, 03-extract-boot.sh and
#   04-create-disk.sh) and the link work/current to it.
#   Running it again on a prepared build is quick and changes nothing.
#
# Environment:
#   All the variables of config.env.

# Load the shared helpers and the configuration.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Read the command line. Options are passed on to every step.
step_options=()
while [ $# -gt 0 ]; do
    case "$1" in
        --force)
            step_options+=(--force)
            ;;
        -h | --help)
            sed -n '3,22p' "$0"
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

# Step 0: the host has everything needed.
"$SCRIPTS_DIR/00-check-host.sh" || exit 1
echo

# "latest" is resolved once here, so that every step works on the same build
# even if a new one is published meanwhile.
build_id="$BUILD_ID"
if [ "$build_id" = "latest" ]; then
    build_id=$(latest_build_id)
    if [ -z "$build_id" ]; then
        die "could not find the latest build on $BASE_URL"
    fi
    info "latest = $build_id"
fi

# Steps 2 to 4. Each one skips what is already done and stops on errors.
"$SCRIPTS_DIR/02-download.sh" "${step_options[@]}" "$build_id" || exit 1
echo
"$SCRIPTS_DIR/03-extract-boot.sh" "${step_options[@]}" "$build_id" || exit 1
echo
"$SCRIPTS_DIR/04-create-disk.sh" "${step_options[@]}" "$build_id" || exit 1
echo

info "Build $build_id is ready (profiles: $(build_info "$(build_dir "$build_id")" profiles))."
info "Next: ./scripts/05-run.sh   (or ./scripts/06-smoke-test.sh to test it first)"
