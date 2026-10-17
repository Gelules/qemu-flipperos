#!/bin/bash
#
# 05-run.sh - boot FlipperOS in QEMU, with the guest console in this terminal.
#
# Usage:
#   ./scripts/05-run.sh [--profile NAME] [BUILD_ID]
#
# Inputs:
#   BUILD_ID         prepared build (default: the build work/current points to).
#   --profile NAME   profile to boot (default: PROFILE from config.env).
#   work/<BUILD_ID>/boot/<Profile>/ and work/<BUILD_ID>/disk.qcow2, from
#   setup.sh (or 03-extract-boot.sh and 04-create-disk.sh).
#
# Outputs:
#   The guest console in this terminal, and a copy of it in
#   work/<BUILD_ID>/logs/run-<Profile>-<date>.log.
#   What you change inside the VM is kept in work/<BUILD_ID>/disk.qcow2.
#
# Keys (QEMU shares the terminal between the guest console and its monitor):
#   Ctrl-a x   quit QEMU at once (like pulling the plug: run "sudo poweroff"
#              in the guest first to stop it cleanly)
#   Ctrl-a c   switch between the guest console and the QEMU monitor
#   Ctrl-a h   list these keys
#
# Environment:
#   PROFILE, ROOT_SUBVOL, MEMORY, CPUS, CPU_MODEL, BIND_ADDR, FLIPCTL_PORT,
#   SSH_PORT, WORK_DIR (see config.env).

# Load the shared helpers and the configuration.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Read the command line.
build_arg=""
while [ $# -gt 0 ]; do
    case "$1" in
        --profile)
            if [ -z "$2" ]; then
                die "--profile needs a profile name"
            fi
            PROFILE="$2"
            shift
            ;;
        -h | --help)
            sed -n '3,27p' "$0"
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

# Find the build directory, the boot files of the profile and the VM disk.
build_id=$(local_build_id "$build_arg") || exit 1
dir=$(build_dir "$build_id")
boot_dir="$dir/boot/$PROFILE"
disk="$dir/disk.qcow2"
if [ ! -d "$dir/boot" ]; then
    die "no boot files for build $build_id. Run ./scripts/setup.sh $build_id first."
fi
if [ ! -f "$boot_dir/vmlinuz" ]; then
    die "no profile \"$PROFILE\" in build $build_id. Profiles: $(build_info "$dir" profiles)"
fi
if [ ! -f "$disk" ]; then
    die "$disk not found. Run ./scripts/04-create-disk.sh $build_id first."
fi

# QEMU cannot forward a port that is already taken, for example by another
# VM started with this script.
for port in "$FLIPCTL_PORT" "$SSH_PORT"; do
    if port_in_use "$port"; then
        die "port $port on $BIND_ADDR is already in use (another VM running?). Choose other ports, for example: FLIPCTL_PORT=8898 SSH_PORT=2223 $0"
    fi
done

# Build the QEMU command line shared with the smoke test.
set_qemu_args "$dir" "$PROFILE" "$disk" "$FLIPCTL_PORT" "$SSH_PORT" || exit 1

# Interactive console: the guest console (hvc0) and the QEMU monitor share
# this terminal (mux=on). signal=off passes Ctrl-C to the guest instead of
# killing QEMU. Everything shown is also written to a log file.
# ("-monitor chardev:..." works with old and new QEMU versions; "-mon" is
# deprecated since QEMU 11.)
mkdir -p "$dir/logs" || die "cannot create $dir/logs"
log="$dir/logs/run-$PROFILE-$(date +%Y%m%d-%H%M%S).log"
QEMU_ARGS+=(
    -chardev "stdio,id=console,mux=on,signal=off,logfile=$log"
    -monitor chardev:console
    -device "virtconsole,chardev=console"
)

# The address to type in a browser: 0.0.0.0 means "every address", and
# localhost is one of them.
host="$BIND_ADDR"
if [ "$host" = "0.0.0.0" ]; then
    host="localhost"
fi

info "Booting FlipperOS build $build_id, profile $PROFILE, kernel $(cat "$boot_dir/kernel-version")"
if [ -n "$ROOT_SUBVOL" ]; then
    info "Root subvolume overridden: $ROOT_SUBVOL"
fi
info "The console stays silent for about 20 seconds, until the guest loads its"
info "virtio console driver; then the boot messages and a login prompt appear."
info "Login: user / user. Quit: Ctrl-a x (run \"sudo poweroff\" first). Monitor: Ctrl-a c"
info "FlipCTL remote view: http://$host:$FLIPCTL_PORT/"
info "SSH: ssh -p $SSH_PORT user@$host"
echo

# Run QEMU in the foreground until the guest powers off or Ctrl-a x.
qemu-system-aarch64 "${QEMU_ARGS[@]}"
status=$?

echo
info "QEMU stopped (exit status $status). Console log: $log"
info "Next: ./scripts/05-run.sh to boot again, or ./scripts/06-smoke-test.sh to test this build."
exit "$status"
