#!/bin/bash
#
# 06-smoke-test.sh - boot FlipperOS without a terminal and check that it works.
#
# The test boots the same virtual machine as 05-run.sh, but headless, on a
# throwaway disk (your VM disk is not touched) and on separate host ports, so
# it can run next to a VM started with 05-run.sh.
#
# Usage:
#   ./scripts/06-smoke-test.sh [--profile NAME] [BUILD_ID]
#   ./scripts/06-smoke-test.sh --help
#
# Inputs:
#   BUILD_ID         prepared build (default: the build set up last, work/current).
#   --profile NAME   profile to test (default: PROFILE from config.env).
#
# Outputs:
#   One PASS, FAIL or WARN line per check, and a summary.
#   Exit status 0 when no check failed, 1 otherwise.
#   The guest console: work/<BUILD_ID>/logs/smoke-<Profile>-<date>.log
#
# Checks:
#   - FlipCTL remote view: GET / returns HTTP 200 with an HTML page, and
#     /stream sends data.
#   - SSH: the port answers with an "SSH-2.0" banner.
#   - Inside the guest, through SSH with the default account (needs sshpass,
#     skipped without it): flipctl.service is active, / is the profile's
#     subvolume, BUILD_ID in /etc/os-release and the kernel version match the
#     image, and the flipctl journal shows it runs without a panel.
#   - Warnings only: the root file system grew to the size of the disk, and
#     the guest clock is right (set by NTP: the kernel has no RTC driver).
#
# Environment:
#   PROFILE, DISK_SIZE, BIND_ADDR, TEST_FLIPCTL_PORT, TEST_SSH_PORT,
#   BOOT_TIMEOUT, NTP_TIMEOUT, GUEST_USER, GUEST_PASSWORD, MEMORY, CPUS,
#   CPU_MODEL, WORK_DIR (see config.env). ROOT_SUBVOL is ignored: the test
#   boots a fresh copy of the image, which only holds the image's profiles.

# Load the shared helpers and the configuration.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh" || exit 1

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

# A subvolume created inside your VM only exists in your VM disk, not in the
# fresh copy of the image that the test boots.
if [ -n "$ROOT_SUBVOL" ]; then
    warn "ROOT_SUBVOL=$ROOT_SUBVOL is ignored: the smoke test boots a fresh copy of the image."
    ROOT_SUBVOL=""
fi

# Find the build directory and the boot files of the profile.
build_id=$(local_build_id "$build_arg") || exit 1
dir=$(build_dir "$build_id")
boot_dir="$dir/boot/$PROFILE"
if [ ! -f "$dir/image.img" ] || [ ! -d "$dir/boot" ]; then
    die "build $build_id is not prepared. Run ./scripts/setup.sh $build_id first."
fi
if [ ! -f "$boot_dir/vmlinuz" ]; then
    die "no profile \"$PROFILE\" in build $build_id. Profiles: $(build_info "$dir" profiles)"
fi

# The test ports must be free.
for port in "$TEST_FLIPCTL_PORT" "$TEST_SSH_PORT"; do
    if port_in_use "$port"; then
        die "port $port on $BIND_ADDR is already in use (another smoke test running?)"
    fi
done

# Address used to reach the forwarded ports.
host="$BIND_ADDR"
if [ "$host" = "0.0.0.0" ]; then
    host="127.0.0.1"
fi

# --- Results ----------------------------------------------------------------

# Count the checks and print one line per check.
passed=0
failed=0
warnings=0

pass() {
    echo "PASS  $*"
    passed=$((passed + 1))
}

fail() {
    echo "FAIL  $*"
    failed=$((failed + 1))
}

warning() {
    echo "WARN  $*"
    warnings=$((warnings + 1))
}

# --- Start the VM -----------------------------------------------------------

# Files of this run. The disk and the PID file are deleted at the end; the
# console log is kept.
mkdir --parents "$dir/logs" || die "cannot create $dir/logs"
log="$dir/logs/smoke-$PROFILE-$(date +%Y%m%d-%H%M%S).log"
test_disk="$dir/smoke-$PROFILE-$$.qcow2"
pidfile="$dir/smoke-$PROFILE-$$.pid"

# Stop QEMU and delete the throwaway disk when the script ends, whatever
# the reason. SIGTERM makes QEMU quit at once; that is fine for a disk we
# throw away. Writing a message to a closed pipe (output sent to "tee", then
# Ctrl-C) must not stop the clean-up, hence "trap '' PIPE".
cleanup() {
    local pid

    trap '' PIPE
    pid=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        info "Stopping QEMU (pid $pid)"
        kill -TERM "$pid"
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid"
        fi
    fi
    rm --force "$pidfile" "$test_disk"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A fresh overlay on the image, of the same size as the VM disk, so that the
# first boot (key generation, file system growth) is tested every time.
if ! qemu-img create -q -f qcow2 -F raw -b image.img "$test_disk" "$DISK_SIZE"; then
    die "qemu-img create failed"
fi

# Same machine as 05-run.sh, with the console written to the log file.
# -daemonize returns once QEMU is running, or with an error if it could not
# start (for example if a port cannot be forwarded).
set_qemu_args "$dir" "$PROFILE" "$test_disk" "$TEST_FLIPCTL_PORT" "$TEST_SSH_PORT" || exit 1
QEMU_ARGS+=(
    -chardev "file,id=console,path=$log"
    -device "virtconsole,chardev=console"
    -pidfile "$pidfile"
    -daemonize
)

# Start the VM in the background and remember its PID and start time.
info "Booting build $build_id, profile $PROFILE, kernel $(cat "$boot_dir/kernel-version")"
info "Console log: $log"
start=$(date +%s)
if ! qemu-system-aarch64 "${QEMU_ARGS[@]}"; then
    die "QEMU did not start"
fi
pid=$(cat "$pidfile")

# --- Wait for the guest -----------------------------------------------------

# Print the first line sent by the SSH server, for example
# "SSH-2.0-OpenSSH_10.0p2 Debian-7", using bash's /dev/tcp.
ssh_banner() {
    local line

    line=$( (exec 3<>"/dev/tcp/$host/$TEST_SSH_PORT" && IFS= read -r -t 10 line <&3 && echo "$line") 2>/dev/null)
    echo "${line%$'\r'}"
}

# Print the HTTP status of a page of the FlipCTL remote view.
http_status() {
    curl --silent --max-time 10 --output /dev/null --write-out '%{http_code}' \
        "http://$host:$TEST_FLIPCTL_PORT$1"
}

# Poll both services until they answer, QEMU dies, or BOOT_TIMEOUT expires.
info "Waiting for FlipCTL and SSH (up to $BOOT_TIMEOUT s; a boot takes about a minute)"
http_after=""
ssh_after=""
while true; do
    if ! kill -0 "$pid" 2>/dev/null; then
        fail "QEMU stopped after $(( $(date +%s) - start )) s (see $log)"
        break
    fi
    if [ -z "$http_after" ] && [ "$(http_status /)" = "200" ]; then
        http_after=$(( $(date +%s) - start ))
        info "FlipCTL answers after $http_after s"
    fi
    if [ -z "$ssh_after" ] && ssh_banner | grep --quiet '^SSH-'; then
        ssh_after=$(( $(date +%s) - start ))
        info "SSH answers after $ssh_after s"
    fi
    if [ -n "$http_after" ] && [ -n "$ssh_after" ]; then
        break
    fi
    if [ $(( $(date +%s) - start )) -ge "$BOOT_TIMEOUT" ]; then
        fail "the guest did not answer within $BOOT_TIMEOUT s (see $log)"
        break
    fi
    sleep 5
done

# --- Checks from the host ---------------------------------------------------

# The remote view page.
page=$(curl --silent --max-time 10 "http://$host:$TEST_FLIPCTL_PORT/")
status=$(http_status /)
if [ "$status" = "200" ] && echo "$page" | grep --quiet --ignore-case '<html\|<!doctype html'; then
    pass "FlipCTL: GET / returns HTTP 200 with an HTML page"
else
    fail "FlipCTL: GET / returned HTTP $status"
fi

# The frame stream never ends: read it for 3 seconds and count the bytes.
bytes=$(curl --silent --max-time 3 "http://$host:$TEST_FLIPCTL_PORT/stream" | wc --bytes)
if [ "$bytes" -gt 0 ]; then
    pass "FlipCTL: /stream sent $bytes bytes in 3 s"
else
    fail "FlipCTL: /stream sent nothing"
fi

# The SSH banner.
banner=$(ssh_banner)
case "$banner" in
    SSH-2.0-*)
        pass "SSH: banner \"$banner\""
        ;;
    *)
        fail "SSH: no SSH-2.0 banner on port $TEST_SSH_PORT"
        ;;
esac

# --- Checks inside the guest ------------------------------------------------

# Run a command in the guest over SSH, with the default password, giving up
# after 60 seconds (--foreground keeps Ctrl-C working meanwhile). The host
# key changes with every fresh disk, so it is neither checked nor saved.
# "-F /dev/null" ignores your SSH configuration (agent forwarding, shared
# connections...): the guest is a test machine.
guest() {
    SSHPASS="$GUEST_PASSWORD" timeout --foreground 60 sshpass -e ssh -F /dev/null -p "$TEST_SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PubkeyAuthentication=no -o LogLevel=ERROR -o ConnectTimeout=20 \
        "$GUEST_USER@$host" "$@"
}

# Same, as root through sudo; the password is sent on the standard input
# (FlipperOS does not ask for it today, but it may one day). The empty prompt
# is written --prompt= because ssh joins the arguments of the remote command
# with spaces, so an empty "" argument would be lost on the way.
guest_root() {
    echo "$GUEST_PASSWORD" | guest sudo -S --prompt= "$@"
}

if ! command -v sshpass >/dev/null 2>&1; then
    warning "sshpass is not installed: checks inside the guest skipped"
elif [ -z "$ssh_after" ]; then
    fail "SSH did not answer: checks inside the guest skipped"
elif [ "$(guest echo ok 2>/dev/null)" != "ok" ]; then
    fail "cannot log in as $GUEST_USER over SSH: checks inside the guest skipped"
else
    # FlipCTL, the Flipper One user interface, runs as a service.
    state=$(guest systemctl is-active flipctl)
    if [ "$state" = "active" ]; then
        pass "guest: flipctl.service is active"
    else
        fail "guest: flipctl.service is \"$state\""
    fi

    # / comes from the subvolume named on the kernel command line.
    expected=$(guest_cmdline "$boot_dir" | grep --only-matching 'subvol=[^ ,]*' | head --lines=1)
    expected=${expected#subvol=}
    expected="/${expected#/}"
    options=$(guest findmnt --noheadings --output OPTIONS /)
    case ",$options," in
        *",subvol=$expected,"*)
            pass "guest: / is mounted from subvol=$expected"
            ;;
        *)
            fail "guest: / is not mounted from subvol=$expected ($options)"
            ;;
    esac

    # The root file system is the one of this image: same os-release build.
    expected=$(sed --quiet 's/^BUILD_ID=//p' "$boot_dir/os-release" | tr --delete '"')
    actual=$(guest sed --quiet 's/^BUILD_ID=//p' /etc/os-release | tr --delete '"')
    if [ -n "$actual" ] && [ "$actual" = "$expected" ]; then
        pass "guest: /etc/os-release has BUILD_ID=$actual"
    else
        fail "guest: /etc/os-release has BUILD_ID=\"$actual\", expected \"$expected\""
    fi

    # The running kernel is the one extracted from the image.
    expected=$(cat "$boot_dir/kernel-version")
    actual=$(guest uname --kernel-release)
    if [ "$actual" = "$expected" ]; then
        pass "guest: kernel $actual"
    else
        fail "guest: kernel \"$actual\", expected \"$expected\""
    fi

    # Without a Flipper display, FlipCTL logs a "panel  none" line and keeps
    # serving the remote view only. Its messages are selected by process name
    # (_COMM): on a real device flipctl runs in a login session, outside the
    # journal of its unit.
    line=$(guest_root journalctl --boot _COMM=flipctl --no-pager --output cat | grep --max-count 1 'panel *none')
    if [ -n "$line" ]; then
        pass "guest: flipctl runs without a panel (\"$line\")"
    else
        fail "guest: no \"panel none\" line in the flipctl journal"
    fi

    # Numbers read from the guest go through "tr" to keep only digits: the
    # guest is not trusted, and bash would run commands hidden in text such
    # as "a[$(...)]" if it reached an arithmetic expression.

    # Warning only: on the first boot, systemd-repart and systemd-growfs make
    # the root partition and file system fill the disk.
    disk_bytes=$(numfmt --from=iec "$DISK_SIZE")
    root_bytes=$(guest df --block-size=1 --output=size / | tail --lines=1 | tr --complement --delete '0-9')
    if [ -n "$root_bytes" ] && [ "$root_bytes" -ge $((disk_bytes * 9 / 10)) ]; then
        pass "guest: the root file system grew to $(numfmt --to=iec-i --suffix=B "$root_bytes") (disk: $DISK_SIZE)"
    else
        warning "guest: the root file system is $(numfmt --to=iec-i --suffix=B "${root_bytes:-0}"), it did not grow to the disk size ($DISK_SIZE)"
    fi

    # Warning only: there is no RTC driver, the clock is set by NTP once the
    # network is up. HTTPS (the app catalogue) needs a correct clock. Wait up
    # to NTP_TIMEOUT seconds for the first synchronization.
    ntp_deadline=$(( $(date +%s) + NTP_TIMEOUT ))
    while true; do
        synced=$(guest timedatectl show --property=NTPSynchronized --value)
        if [ "$synced" = "yes" ] || [ "$(date +%s)" -ge "$ntp_deadline" ]; then
            break
        fi
        sleep 5
    done
    guest_time=$(guest date +%s | tr --complement --delete '0-9')
    offset=$(( ${guest_time:-0} - $(date +%s) ))
    if [ "$synced" = "yes" ] && [ "${offset#-}" -le 10 ]; then
        pass "guest: clock synchronized by NTP (offset ${offset} s from the host)"
    else
        warning "guest: clock not synchronized by NTP (NTPSynchronized=$synced, offset ${offset} s from the host)"
    fi
fi

# --- Summary ----------------------------------------------------------------

echo
info "Build $build_id, profile $PROFILE: $passed passed, $failed failed, $warnings warning(s)."
info "Boot: FlipCTL after ${http_after:-?} s, SSH after ${ssh_after:-?} s. Console log: $log"
if [ "$failed" -gt 0 ]; then
    info "Next: read the console log above, and the troubleshooting section of README.md."
    exit 1
fi
info "Next: ./scripts/05-run.sh $build_id   (interactive VM)"
