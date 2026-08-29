#!/usr/bin/env bash
set -euo pipefail

# This is intentionally a process-lifecycle test, not a mock of the runner.
# It copies the public scripts into a tiny project, sends real signals to their
# PIDs, and verifies the PIDs and process group recorded by the payload.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/moonstone-runner-cancel.XXXXXX")"
ACTIVE_CASE_DIR=""
ACTIVE_TARGET_PID=""
ACTIVE_TARGET_PGID=""
TEST_PGID="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')"
TEST_PID="$$"

kill_fixture_processes() {
    local group_file group observed_parent observed_group
    # Only the in-progress case is armed.  Completed-case PIDs may be reused,
    # so this watchdog must never walk old fixture files and address them.
    if [[ -n "${ACTIVE_CASE_DIR}" ]]; then
        group_file="${ACTIVE_CASE_DIR}/control.group"
        if [[ -f "${group_file}" ]]; then
            group="$(<"${group_file}")"
            if [[ "${group}" =~ ^[0-9]+$ ]]; then
                read -r observed_parent observed_group <<EOF
$(ps -o ppid= -o pgid= -p "${group}" 2>/dev/null)
EOF
                [[ "${observed_parent}" == "${ACTIVE_TARGET_PID}" && \
                   "${observed_group}" == "${group}" ]] && kill -KILL -- "-${group}" 2>/dev/null || true
            fi
        fi
    fi
    # The launcher is also addressed only as a verified process group.  Do not
    # use a saved positive PID: Bash may already have reaped an async child.
    if [[ -n "${ACTIVE_TARGET_PID}" && -n "${ACTIVE_TARGET_PGID}" ]]; then
        read -r observed_parent observed_group <<EOF
$(ps -o ppid= -o pgid= -p "${ACTIVE_TARGET_PID}" 2>/dev/null)
EOF
        if [[ "${observed_parent}" == "${TEST_PID}" && \
              "${observed_group}" == "${ACTIVE_TARGET_PID}" && \
              "${observed_group}" == "${ACTIVE_TARGET_PGID}" && \
              "${observed_group}" != "${TEST_PGID}" ]]; then
            kill -KILL -- "-${ACTIVE_TARGET_PGID}" 2>/dev/null || true
        fi
    fi
    return 0
}

cleanup() {
    kill_fixture_processes
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${TMP_DIR}/tests/scripts" "${TMP_DIR}/tests/e2e/cancel" "${TMP_DIR}/fake-bin"
cp "${ROOT_DIR}/tests/scripts/run_tests.sh" "${TMP_DIR}/tests/scripts/run_tests.sh"
cp "${ROOT_DIR}/tests/run-synthetic.sh" "${TMP_DIR}/tests/run-synthetic.sh"
chmod +x "${TMP_DIR}/tests/scripts/run_tests.sh" "${TMP_DIR}/tests/run-synthetic.sh"
printf '#!/usr/bin/env bash\n' > "${TMP_DIR}/tests/scripts/install_synthetic.sh"
cat > "${TMP_DIR}/fake-bin/zig" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${TMP_DIR}/tests/run_lua_tool.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP_DIR}/fake-bin/zig" "${TMP_DIR}/tests/run_lua_tool.sh"

write_cancel_suite() {
    local case_dir="$1"
    mkdir -p "${case_dir}"
    cat > "${TMP_DIR}/tests/e2e/cancel/01_signal_tree.sh" <<EOF
#!/usr/bin/env bash
case_dir="${case_dir}"
control_pid="\$PPID"
runner_pid="\$(ps -o ppid= -p "\${control_pid}" | tr -d '[:space:]')"
group="\$(ps -o pgid= -p "\${control_pid}" | tr -d '[:space:]')"
printf '%s' "\${runner_pid}" > "\${case_dir}/runner.pid"
printf '%s' "\${control_pid}" > "\${case_dir}/control.pid"
printf '%s' "\${group}" > "\${case_dir}/control.group"
( trap '' INT TERM; exec sleep 1000 ) &
printf '%s' "\$!" > "\${case_dir}/preexisting.pid"
ps -o pgid= -p "\$!" | tr -d '[:space:]' > "\${case_dir}/preexisting.group"
handle_signal() {
    printf '%s' "\$1" > "\${case_dir}/received.signal"
    ( trap '' INT TERM; exec sleep 1000 ) &
    printf '%s' "\$!" > "\${case_dir}/handler.pid"
    ps -o pgid= -p "\$!" | tr -d '[:space:]' > "\${case_dir}/handler.group"
    exit 0
}
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM
printf ready > "\${case_dir}/ready"
while :; do sleep 1; done
EOF
    cat > "${TMP_DIR}/tests/e2e/cancel/02_must_not_start.sh" <<EOF
#!/usr/bin/env bash
printf started > "${case_dir}/second.started"
EOF
    chmod +x "${TMP_DIR}/tests/e2e/cancel"/*.sh
}

wait_for_file() {
    local file="$1"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
             21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
        [[ -s "${file}" ]] && return 0
        sleep 0.05
    done
    return 1
}

target_group_is_current() {
    local observed_parent observed_group
    [[ -n "${ACTIVE_TARGET_PID}" && -n "${ACTIVE_TARGET_PGID}" ]] || return 1
    read -r observed_parent observed_group <<EOF
$(ps -o ppid= -o pgid= -p "${ACTIVE_TARGET_PID}" 2>/dev/null)
EOF
    [[ "${observed_parent}" == "${TEST_PID}" && \
       "${observed_group}" == "${ACTIVE_TARGET_PID}" && \
       "${observed_group}" == "${ACTIVE_TARGET_PGID}" && \
       "${observed_group}" != "${TEST_PGID}" ]]
}

group_is_empty() {
    local group="$1"
    local pid observed
    while read -r pid observed; do
        [[ "${observed}" == "${group}" ]] && return 1
    done < <(ps -ax -o pid= -o pgid=)
    return 0
}

assert_reaped() {
    local case_dir="$1"
    local pid_file pid i group
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
             21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
        group="$(<"${case_dir}/control.group")"
        group_is_empty "${group}" && break
        sleep 0.05
    done
    group_is_empty "${group}"
    for pid_file in "${case_dir}"/control.pid "${case_dir}"/preexisting.pid "${case_dir}"/handler.pid; do
        pid="$(<"${pid_file}")"
        ! kill -0 "${pid}" 2>/dev/null
    done
}

run_signal_case() {
    local entry_kind="$1"
    local signal="$2"
    local expected="$3"
    local delivery="$4"
    local case_dir="${TMP_DIR}/case-${entry_kind}-${signal}"
    local target_pid target_pgid runner_status runner_pid

    ACTIVE_CASE_DIR="${case_dir}"
    write_cancel_suite "${case_dir}"
    set -m
    if [[ "${entry_kind}" == runner ]]; then
        ( cd "${TMP_DIR}" && exec bash tests/scripts/run_tests.sh --suite cancel ) >"${case_dir}/log" 2>&1 &
    else
        ( cd "${TMP_DIR}" && PATH="${TMP_DIR}/fake-bin:${PATH}" exec bash tests/run-synthetic.sh ) >"${case_dir}/log" 2>&1 &
    fi
    target_pid="$!"
    ACTIVE_TARGET_PID="${target_pid}"
    target_pgid="$(ps -o pgid= -p "${target_pid}" 2>/dev/null | tr -d '[:space:]')"
    [[ "${target_pgid}" == "${target_pid}" && "${target_pgid}" != "${TEST_PGID}" ]]
    ACTIVE_TARGET_PGID="${target_pgid}"
    set +m

    wait_for_file "${case_dir}/ready"
    runner_pid="$(<"${case_dir}/runner.pid")"
    # run-synthetic must have exec'd its runner: a direct signal to the
    # bootstrapper PID is now a direct signal to the ownership controller.
    [[ "${runner_pid}" == "${target_pid}" ]]
    target_group_is_current
    if [[ "${delivery}" == terminal ]]; then
        # A terminal delivers Ctrl-C to its foreground job's process group.
        # This job-control group has the normal SIGINT disposition, unlike a
        # noninteractive `bash script &` child which POSIX requires to inherit
        # SIG_IGN and which a shell trap cannot repair.
        kill -s INT -- "-${target_pgid}"
    else
        # SIGTERM is delivered directly to the bootstrapper/runner process.
        # It is still a live, verified job-control group leader at this point.
        kill -s TERM "${target_pid}"
    fi
    set +e
    wait "${target_pid}" 2>/dev/null
    runner_status="$?"
    set -e

    [[ "${runner_status}" -eq "${expected}" ]]
    [[ "$(<"${case_dir}/received.signal")" == "${signal}" ]]
    [[ ! -e "${case_dir}/second.started" ]]
    [[ -s "${case_dir}/handler.pid" ]]
    [[ "$(<"${case_dir}/preexisting.group")" == "$(<"${case_dir}/control.group")" ]]
    [[ "$(<"${case_dir}/handler.group")" == "$(<"${case_dir}/control.group")" ]]
    assert_reaped "${case_dir}"
    ACTIVE_TARGET_PID=""
    ACTIVE_TARGET_PGID=""
    ACTIVE_CASE_DIR=""
}

# Both direct runner and bootstrapper paths exercise terminal-like Ctrl-C and
# direct TERM.  Do not claim support for SIGINT sent to `bash script &` with
# monitor mode off: inherited SIG_IGN is an irreversible POSIX exec property.
run_signal_case runner INT 130 terminal
run_signal_case runner TERM 143 direct
run_signal_case synthetic INT 130 terminal
run_signal_case synthetic TERM 143 direct

write_lost_owner_suite() {
    local case_dir="$1"
    mkdir -p "${case_dir}"
    cat > "${TMP_DIR}/tests/e2e/cancel/01_lost_owner.sh" <<EOF
#!/usr/bin/env bash
case_dir="${case_dir}"
control_pid="\$PPID"
printf '%s' "\${control_pid}" > "\${case_dir}/control.pid"
ps -o pgid= -p "\${control_pid}" | tr -d '[:space:]' > "\${case_dir}/control.group"
printf '%s' "\$\$" > "\${case_dir}/payload.pid"
trap 'printf received > "\${case_dir}/unexpected.signal"; exit 1' TERM
printf ready > "\${case_dir}/ready"
sleep 1
EOF
    chmod +x "${TMP_DIR}/tests/e2e/cancel/01_lost_owner.sh"
    rm -f "${TMP_DIR}/tests/e2e/cancel/02_must_not_start.sh"
}

wait_for_pid_gone() {
    local pid="$1"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
             21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
        ! kill -0 "${pid}" 2>/dev/null && return 0
        sleep 0.05
    done
    return 1
}

# If an external actor kills the anchor, the runner must return the requested
# status without using either the old leader PID or its old process group.  The
# finite payload lets this adversarial regression clean up without unsafe PID
# targeting of its own.
lost_dir="${TMP_DIR}/case-lost-owner"
ACTIVE_CASE_DIR="${lost_dir}"
write_lost_owner_suite "${lost_dir}"
set -m
( cd "${TMP_DIR}" && exec bash tests/scripts/run_tests.sh --suite cancel ) >"${lost_dir}/log" 2>&1 &
lost_target="$!"
ACTIVE_TARGET_PID="${lost_target}"
lost_target_pgid="$(ps -o pgid= -p "${lost_target}" 2>/dev/null | tr -d '[:space:]')"
[[ "${lost_target_pgid}" == "${lost_target}" && "${lost_target_pgid}" != "${TEST_PGID}" ]]
ACTIVE_TARGET_PGID="${lost_target_pgid}"
set +m
wait_for_file "${lost_dir}/ready"
lost_control="$(<"${lost_dir}/control.pid")"
lost_group="$(<"${lost_dir}/control.group")"
read -r lost_parent lost_observed_group <<EOF
$(ps -o ppid= -o pgid= -p "${lost_control}" 2>/dev/null)
EOF
[[ "${lost_parent}" == "${lost_target}" && "${lost_observed_group}" == "${lost_control}" ]]
[[ "${lost_group}" == "${lost_control}" ]]
# This deliberately simulates an independent actor killing the verified group
# leader only. It is not a cached fallback: identity is proven immediately.
kill -KILL "${lost_control}"
target_group_is_current
kill -TERM "${lost_target}"
set +e
wait "${lost_target}" 2>/dev/null
lost_status="$?"
set -e
[[ "${lost_status}" -eq 143 ]]
[[ ! -e "${lost_dir}/unexpected.signal" ]]
grep -q 'control group ownership was lost' "${lost_dir}/log"
wait_for_pid_gone "$(<"${lost_dir}/payload.pid")"
group_is_empty "${lost_group}"
ACTIVE_TARGET_PID=""
ACTIVE_TARGET_PGID=""
ACTIVE_CASE_DIR=""

write_completed_suite() {
    local case_dir="$1"
    mkdir -p "${case_dir}" "${TMP_DIR}/tests/e2e/complete"
    cat > "${TMP_DIR}/tests/e2e/complete/01_background_success.sh" <<EOF
#!/usr/bin/env bash
case_dir="${case_dir}"
control_pid="\$PPID"
printf '%s' "\${control_pid}" > "\${case_dir}/control.pid"
ps -o pgid= -p "\${control_pid}" | tr -d '[:space:]' > "\${case_dir}/control.group"
( trap '' INT TERM; exec sleep 1000 ) &
printf '%s' "\$!" > "\${case_dir}/background.pid"
ps -o pgid= -p "\$!" | tr -d '[:space:]' > "\${case_dir}/background.group"
exit 0
EOF
    chmod +x "${TMP_DIR}/tests/e2e/complete/01_background_success.sh"
}

assert_completed_group_reaped() {
    local case_dir="$1"
    local group pid i
    group="$(<"${case_dir}/control.group")"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
             21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
        group_is_empty "${group}" && break
        sleep 0.05
    done
    group_is_empty "${group}"
    [[ "$(<"${case_dir}/background.group")" == "${group}" ]]
    for pid in "$(<"${case_dir}/control.pid")" "$(<"${case_dir}/background.pid")"; do
        ! kill -0 "${pid}" 2>/dev/null
    done
}

run_completed_case() {
    local signal="${1:-}"
    local expected="${2:-0}"
    local delivery="${3:-}"
    local case_dir="${TMP_DIR}/case-completed-${signal:-normal}"
    local gate="${case_dir}/status-gate"
    local target target_pgid status

    ACTIVE_CASE_DIR="${case_dir}"
    write_completed_suite "${case_dir}"
    set -m
    if [[ -n "${signal}" ]]; then
        ( cd "${TMP_DIR}" && MOONSTONE_TEST_STATUS_GATE="${gate}" exec bash tests/scripts/run_tests.sh --suite complete ) >"${case_dir}/log" 2>&1 &
    else
        ( cd "${TMP_DIR}" && exec bash tests/scripts/run_tests.sh --suite complete ) >"${case_dir}/log" 2>&1 &
    fi
    target="$!"
    ACTIVE_TARGET_PID="${target}"
    target_pgid="$(ps -o pgid= -p "${target}" 2>/dev/null | tr -d '[:space:]')"
    [[ "${target_pgid}" == "${target}" && "${target_pgid}" != "${TEST_PGID}" ]]
    ACTIVE_TARGET_PGID="${target_pgid}"
    set +m

    if [[ -n "${signal}" ]]; then
        wait_for_file "${gate}.ready"
        target_group_is_current
        if [[ "${delivery}" == terminal ]]; then
            kill -INT -- "-${target_pgid}"
        else
            kill -TERM "${target}"
        fi
    fi
    set +e
    wait "${target}" 2>/dev/null
    status="$?"
    set -e
    [[ "${status}" -eq "${expected}" ]]
    assert_completed_group_reaped "${case_dir}"
    ACTIVE_TARGET_PID=""
    ACTIVE_TARGET_PGID=""
    ACTIVE_CASE_DIR=""
}

# A successful payload is not complete until its signal-ignoring background
# child is KILLed with the anchored group. Also exercise cancellation after the
# runner has read the payload status but before ordinary teardown.
run_completed_case
run_completed_case INT 130 terminal
run_completed_case TERM 143 direct

# Repeated immediate delivery covers the registration/gate race.  Cancellation
# is sticky, so either no payload starts or any payload that won the scheduler
# race is cleaned before the next test can launch.
for attempt in 1 2 3 4 5 6 7 8; do
    early_dir="${TMP_DIR}/case-early-${attempt}"
    ACTIVE_CASE_DIR="${early_dir}"
    write_cancel_suite "${early_dir}"
    set -m
    ( cd "${TMP_DIR}" && exec bash tests/scripts/run_tests.sh --suite cancel ) >"${early_dir}/log" 2>&1 &
    early_pid="$!"
    ACTIVE_TARGET_PID="${early_pid}"
    early_pgid="$(ps -o pgid= -p "${early_pid}" 2>/dev/null | tr -d '[:space:]')"
    [[ "${early_pgid}" == "${early_pid}" && "${early_pgid}" != "${TEST_PGID}" ]]
    ACTIVE_TARGET_PGID="${early_pgid}"
    set +m
    target_group_is_current
    kill -TERM "${early_pid}"
    set +e
    wait "${early_pid}" 2>/dev/null
    early_status="$?"
    set -e
    [[ "${early_status}" -eq 143 ]]
    [[ ! -e "${early_dir}/second.started" ]]
    ACTIVE_TARGET_PID=""
    ACTIVE_TARGET_PGID=""
    ACTIVE_CASE_DIR=""
done

normal_dir="${TMP_DIR}/tests/e2e/normal"
mkdir -p "${normal_dir}"
printf '#!/usr/bin/env bash\nexit 0\n' > "${normal_dir}/01_pass.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "${normal_dir}/02_fail.sh"
chmod +x "${normal_dir}"/*.sh
set +e
( cd "${TMP_DIR}" && exec bash tests/scripts/run_tests.sh --suite normal ) >"${TMP_DIR}/normal.log" 2>&1
normal_status="$?"
set -e
[[ "${normal_status}" -eq 1 ]]
[[ "$(grep -c '01_pass.sh passed' "${TMP_DIR}/normal.log")" -eq 1 ]]
[[ "$(grep -c '02_fail.sh failed' "${TMP_DIR}/normal.log")" -eq 1 ]]
[[ "$(grep -c 'Final Results: 1 passed, 1 failed' "${TMP_DIR}/normal.log")" -eq 1 ]]

printf 'runner cancellation tests passed\n'
