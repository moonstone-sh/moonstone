#!/usr/bin/env bash
set -uo pipefail

# Runs the synthetic E2E suites.  Each test gets a process group owned by a
# persistent control shell.  That is deliberately stronger than following a
# snapshot of descendant PIDs: children which a signal handler starts after
# their parent exits still belong to the owned group.

export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="${PROJECT_ROOT}/tests/e2e"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
SANDBOX_DIR="${PROJECT_ROOT}/fixtures/sandbox"

SUITE=""
INCLUDE_REAL_ROCKS=false

usage() {
    cat <<'USAGE'
Usage: tests/scripts/run_tests.sh [--suite <suite_name> | --all] [--include-real-rocks]

Runs isolated Moonstone E2E suites. By default, tests that download pinned
upstream LuaRocks releases are skipped. Pass --include-real-rocks to opt into
those network and native-toolchain contracts.
USAGE
}

while (($#)); do
    case "$1" in
        --suite)
            SUITE="${2:-}"
            if [[ -z "${SUITE}" ]]; then
                usage >&2
                exit 64
            fi
            shift 2
            ;;
        --all)
            shift
            ;;
        --include-real-rocks)
            INCLUDE_REAL_ROCKS=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
done

PASS=0
FAIL=0
SKIP=0
TEST_NUMBER=0
CANCELLED_STATUS=""
CANCELLED_SIGNAL=""
ACTIVE_CONTROL_PID=""
ACTIVE_PGID=""
ACTIVE_GROUP_VERIFIED=0
RUNNER_PGID="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')"
RUNNER_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/moonstone-runner.XXXXXX")"

cleanup_runner() {
    rm -rf "${RUNNER_TMP_DIR}"
}
trap cleanup_runner EXIT

# Bash monitor mode gives each asynchronous job its own process group on both
# macOS Bash 3.2 and Linux Bash.  We do not trust that promise blindly: no test
# is released from its gate until ps proves that $! is also that group's leader
# and that it is not the runner/caller group.
# SIGINT is supported for a terminal foreground job (and a job-control launch
# with a normal disposition). POSIX preserves SIG_IGN across exec, so a runner
# started as noninteractive `bash script &` without job control cannot repair
# its inherited ignored SIGINT in shell code; direct SIGTERM remains supported.
set -m

request_cancellation() {
    CANCELLED_SIGNAL="$1"
    CANCELLED_STATUS="$2"
    # Preserve the first conventional status and let the main path reap the
    # direct child; doing waits from a trap which interrupted a wait is brittle
    # across the Bash versions we support.
    trap '' INT TERM
}
trap 'request_cancellation INT 130' INT
trap 'request_cancellation TERM 143' TERM

control_group_is_owned() {
    local observed_parent
    local observed_group
    [[ "${ACTIVE_GROUP_VERIFIED}" -eq 1 ]] || return 1
    [[ -n "${ACTIVE_CONTROL_PID}" && -n "${ACTIVE_PGID}" ]] || return 1
    read -r observed_parent observed_group <<EOF
$(ps -o ppid= -o pgid= -p "${ACTIVE_CONTROL_PID}" 2>/dev/null)
EOF
    [[ "${observed_parent}" == "$$" && \
       "${observed_group}" == "${ACTIVE_CONTROL_PID}" && \
       "${observed_group}" == "${ACTIVE_PGID}" && \
       "${observed_group}" != "${RUNNER_PGID}" ]]
}

signal_owned_group() {
    local signal="$1"
    control_group_is_owned || return 1
    # The control shell remains alive until this runner explicitly releases or
    # kills it.  Therefore a verified negative PID names our group, not a
    # recycled one, for the whole TERM/INT grace period.
    kill -s "${signal}" -- "-${ACTIVE_PGID}" 2>/dev/null
}

finish_completed_test_group() {
    # A passing payload can leave background work behind. Its status is already
    # captured, but the test is not complete until its entire owned group is
    # gone. Do not release the anchor normally: KILL the verified group and
    # reap the anchor before another test can begin.
    if ! signal_owned_group KILL; then
        echo "runner completion: control group ownership was lost; no unverified process was killed" >&2
        forget_active_control
        return 1
    fi
    reap_active_control
    return 0
}

wait_for_test_status_gate() {
    local gate="${MOONSTONE_TEST_STATUS_GATE:-}"
    local i
    [[ -n "${gate}" ]] || return 0
    printf 'ready\n' > "${gate}.ready"
    # Regression-only synchronization. It is inert unless explicitly set and
    # bounded so a malformed test invocation cannot hang the regular runner.
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
             21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
        [[ -f "${gate}.release" ]] && return 0
        exit_if_cancelled
        sleep 0.05
    done
    return 0
}

clear_active_test() {
    ACTIVE_CONTROL_PID=""
    ACTIVE_PGID=""
    ACTIVE_GROUP_VERIFIED=0
}

reap_active_control() {
    local control_pid="${ACTIVE_CONTROL_PID}"
    [[ -n "${control_pid}" ]] || return 0
    wait "${control_pid}" 2>/dev/null || true
    clear_active_test
}

forget_active_control() {
    # wait is deliberately not used here.  Once the leader is no longer a
    # verified group leader it may be waiting on the startup gate forever, and
    # this runner cannot either signal it or safely assume that a later wait
    # refers to the original process on every Bash implementation.
    clear_active_test
}

cancel_active_test() {
    local i

    [[ -n "${ACTIVE_CONTROL_PID}" ]] || return 0

    # There is intentionally no positive-PID fallback.  Bash may reap an async
    # child before an explicit wait, so an old numeric PID is not a durable
    # identity.  If the leader no longer proves ownership, safety requires us
    # to leave the unknown process alone.
    if ! signal_owned_group "${CANCELLED_SIGNAL}"; then
        echo "runner cancellation: control group ownership was lost; no unverified process was signalled" >&2
        forget_active_control
        return 0
    fi

    # This is intentionally bounded.  The anchor does not exit on INT/TERM;
    # it holds the PGID while tests run handlers and while their newly-created
    # descendants join the same group.
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.1
    done

    # Never issue a delayed negative-PID kill unless the original direct child
    # still proves ownership.  If an external actor killed that child, safety
    # (not touching a recycled group) wins over an unverified broad signal.
    if ! signal_owned_group KILL; then
        echo "runner cancellation: control group ownership was lost during grace; no unverified process was killed" >&2
        forget_active_control
        return 0
    fi
    reap_active_control
}

exit_if_cancelled() {
    if [[ -n "${CANCELLED_STATUS}" ]]; then
        cancel_active_test
        exit "${CANCELLED_STATUS}"
    fi
}

is_real_rocks_contract() {
    case "$(basename "$1")" in
        cqueues_real_contract.sh|luafilesystem_real_contract.sh|luajit_real_luarocks_http_api.sh|luaposix_real_contract.sh|luasql_sqlite3_real_contract.sh|luv_real_contract.sh)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

run_test_file() {
    local test_file="$1"
    local suite_name="$2"
    local label
    local gate_file
    local status_file
    local test_status

    label="$(basename "${test_file}")"
    exit_if_cancelled

    if [[ "${INCLUDE_REAL_ROCKS}" != true ]] && is_real_rocks_contract "${test_file}"; then
        echo "  - ${label} skipped (use --include-real-rocks to run pinned upstream contracts)"
        ((SKIP+=1))
        return 0
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Running Test: [${suite_name}] ${label}"
    echo "═══════════════════════════════════════════════════════════════════"

    ((TEST_NUMBER+=1))
    gate_file="${RUNNER_TMP_DIR}/${TEST_NUMBER}.gate"
    status_file="${RUNNER_TMP_DIR}/${TEST_NUMBER}.status"

    # The control shell is the group leader and remains in the group after the
    # payload completes.  Its caught (rather than ignored) INT/TERM traps keep
    # the anchor alive, while exec resets those caught dispositions to default
    # for the foreground test Bash.  The child Bash explicitly disables monitor
    # mode: its ordinary background helpers must remain in this owned group,
    # rather than acquiring their own job-control groups. This is not an
    # attempted repair for an already ignored SIGINT inherited by the runner;
    # that POSIX limitation is documented above.
    (
        trap ':' INT TERM
        # If the parent cannot establish a group, no payload is released.  A
        # bounded gate wait makes that partial initialization self-cleaning
        # without a risky positive-PID fallback in the parent.
        gate_wait=0
        while [[ ! -f "${gate_file}" && "${gate_wait}" -lt 100 ]]; do
            sleep 0.05
            ((gate_wait+=1))
        done
        [[ -f "${gate_file}" ]] || exit 125
        source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
        export PATH="${MOON_BIN%/*}:${PATH}"
        export SANDBOX_DIR
        if [[ "${INCLUDE_REAL_ROCKS}" == true ]]; then
            export MOONSTONE_REAL_LUAROCKS=1
        else
            export MOONSTONE_REAL_LUAROCKS=0
        fi
        if bash +m "${test_file}"; then
            test_status=0
        else
            test_status=$?
        fi
        printf '%s\n' "${test_status}" > "${status_file}"
        # The parent owns final group cleanup; remain its verified anchor until
        # KILL, including after the payload has reported its status.
        while :; do sleep 1; done
        exit "${test_status}"
    ) &
    ACTIVE_CONTROL_PID="$!"
    ACTIVE_PGID="$(ps -o pgid= -p "${ACTIVE_CONTROL_PID}" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "${ACTIVE_PGID}" && "${ACTIVE_PGID}" == "${ACTIVE_CONTROL_PID}" && "${ACTIVE_PGID}" != "${RUNNER_PGID}" ]]; then
        ACTIVE_GROUP_VERIFIED=1
    fi

    # A signal may arrive before $! was registered, between registration and
    # verification, or immediately before this gate opens.  In all cases it
    # prevents a launch or routes through the same bounded cleanup path.
    exit_if_cancelled
    if ! control_group_is_owned; then
        echo "  ✗ ${label} failed (could not establish isolated process group)"
        # The anchor has not received its gate and exits by itself shortly.
        # Do not signal an unverified PID.
        forget_active_control
        ((FAIL+=1))
        return 0
    fi
    touch "${gate_file}"

    while [[ ! -s "${status_file}" ]]; do
        exit_if_cancelled
        sleep 0.05
    done
    test_status="$(<"${status_file}")"

    # A cancellation in this deliberate post-status window must still clean the
    # anchored group and select 130/143 rather than count the saved test status.
    wait_for_test_status_gate
    exit_if_cancelled
    if ! finish_completed_test_group; then
        echo "  ✗ ${label} failed (lost control of completed test group)"
        ((FAIL+=1))
        return 0
    fi
    # A trap can run while normal KILL/reap is in progress. The group is gone
    # and active state is clear, but the cancellation status remains sticky.
    exit_if_cancelled

    if (( test_status == 0 )); then
        echo "  ✓ ${label} passed"
        ((PASS+=1))
    else
        echo "  ✗ ${label} failed"
        ((FAIL+=1))
    fi
}

if [[ -n "${SUITE}" ]]; then
    TARGET_DIR="${TESTS_DIR}/${SUITE}"
    if [[ ! -d "${TARGET_DIR}" ]]; then
        echo "Error: Suite '${SUITE}' not found at ${TARGET_DIR}"
        exit 1
    fi
    for f in "${TARGET_DIR}"/*.sh; do
        exit_if_cancelled
        [[ -f "${f}" ]] && run_test_file "${f}" "${SUITE}"
    done
else
    for suite_dir in "${TESTS_DIR}"/*; do
        exit_if_cancelled
        if [[ -d "${suite_dir}" ]]; then
            suite_name="$(basename "${suite_dir}")"
            for f in "${suite_dir}"/*.sh; do
                exit_if_cancelled
                [[ -f "${f}" ]] && run_test_file "${f}" "${suite_name}"
            done
        fi
    done
fi

exit_if_cancelled
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Final Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "═══════════════════════════════════════════════════════════════════"

if (( FAIL > 0 )); then
    exit 1
fi
