#!/usr/bin/env bash
set -euo pipefail

readonly demo_source="/opt/rocks-parallel-demo"
readonly report_dir="${BENCHMARK_REPORT_DIR:-/work/report}"
readonly run_count="${BENCHMARK_RUNS:-3}"
readonly benchmark_suite="${BENCHMARK_SUITE:-clean}"
readonly moonstone_jobs="${MOONSTONE_BENCHMARK_JOBS:-8}"
readonly -a rocks=(
    "ansicolors 1.0.2-1"
    "argparse 0.7.2-1"
    "dkjson 2.11-1"
    "inspect 3.1.3-0"
    "fun 0.1.3-1"
    "penlight 1.15.0-1"
    "lpeg 1.1.0-2"
    "luafilesystem 1.9.0-1"
    "luasocket 3.1.0-1"
)

cleanup_paths=()
case_dir=""

cleanup() {
    local path
    for path in "${cleanup_paths[@]:-}"; do
        rm -rf "${path}"
    done
}
trap cleanup EXIT

make_case_dir() {
    local suite="$1"
    local tool="$2"
    local run="$3"
    case_dir="$(mktemp -d "/tmp/moonstone-luarocks-benchmark.${suite}.${tool}.${run}.XXXXXX")"
    cleanup_paths+=("${case_dir}")
}

write_moonstone_manifest() {
    local app_dir="$1"
    local name="$2"
    local with_dependencies="$3"
    local rock name_part version_part

    mkdir -p "${app_dir}/src"
    cp "${demo_source}/src/verify.lua" "${app_dir}/src/verify.lua"
    cat >"${app_dir}/moonstone.toml" <<EOF
manifest_version = 2

[package]
name = "${name}"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[scripts]
verify = 'lua src/verify.lua "\$@"'
EOF

    if [[ "${with_dependencies}" != "true" ]]; then
        return
    fi

    for rock in "${rocks[@]}"; do
        read -r name_part version_part <<<"${rock}"
        cat >>"${app_dir}/moonstone.toml" <<EOF

[[dependencies]]
name = "${name_part}"
constraint = "=${version_part}"
registry = "rocks"
role = "runtime"
EOF
    done
}

emit_result() {
    local suite="$1"
    local tool="$2"
    local run="$3"
    local elapsed="$4"
    jq -cn \
        --arg contract "moonstone:luarocks-comparison:v2" \
        --arg suite "${suite}" \
        --arg tool "${tool}" \
        --arg build_mode "${MOONSTONE_BENCHMARK_BUILD_MODE:-unknown}" \
        --argjson run "${run}" \
        --argjson elapsed_seconds "${elapsed}" \
        --argjson moonstone_jobs "${moonstone_jobs}" \
        '{ contract: $contract, suite: $suite, tool: $tool, run: $run, elapsed_seconds: $elapsed_seconds, moonstone_jobs: $moonstone_jobs, moonstone_build_mode: $build_mode }' \
        | tee -a "${report_dir}/results.ndjson"
}

run_timed() {
    local suite="$1"
    local tool="$2"
    local run="$3"
    shift 3
    local time_file="${report_dir}/${suite}-${tool}-${run}.time"
    local log_file="${report_dir}/${suite}-${tool}-${run}.log"

    if ! /usr/bin/time -p "$@" >"${log_file}" 2>"${time_file}"; then
        cat "${log_file}" >&2
        cat "${time_file}" >&2
        return 1
    fi

    local elapsed
    elapsed="$(awk '$1 == "real" { print $2 }' "${time_file}")"
    if [[ -z "${elapsed}" ]]; then
        echo "ERROR: timing result missing for ${suite}/${tool} run ${run}" >&2
        cat "${time_file}" >&2
        return 1
    fi
    emit_result "${suite}" "${tool}" "${run}" "${elapsed}"

    if [[ "${BENCHMARK_SHOW_LOGS:-0}" == "1" ]]; then
        printf '\n--- %s/%s run %s output ---\n' "${suite}" "${tool}" "${run}" >&2
        cat "${log_file}" >&2
        cat "${time_file}" >&2
    fi
}

run_moonstone_clean() {
    local run="$1"
    make_case_dir clean moonstone "${run}"
    local moonstone_case_dir="${case_dir}"
    write_moonstone_manifest "${moonstone_case_dir}/app" "benchmark-clean" true

    run_timed clean moonstone "${run}" env \
        HOME="${moonstone_case_dir}/home" \
        XDG_CONFIG_HOME="${moonstone_case_dir}/xdg-config" \
        XDG_DATA_HOME="${moonstone_case_dir}/xdg-data" \
        XDG_CACHE_HOME="${moonstone_case_dir}/xdg-cache" \
        MOONSTONE_HOME="${moonstone_case_dir}/moonstone-home" \
        MOONSTONE_CONFIG="${moonstone_case_dir}/moonstone-config" \
        MOONSTONE_DATA="${moonstone_case_dir}/moonstone-data" \
        MOONSTONE_CACHE="${moonstone_case_dir}/moonstone-cache" \
        bash -c 'set -euo pipefail; cd "$1"; moon sync --jobs "$2" --progress plain; moon run verify -- --json >/dev/null' -- \
        "${moonstone_case_dir}/app" "${moonstone_jobs}"
}

run_moonstone_dependencies() {
    local run="$1"
    make_case_dir dependencies moonstone "${run}"
    local moonstone_case_dir="${case_dir}"
    write_moonstone_manifest "${moonstone_case_dir}/runtime" "benchmark-runtime" false
    write_moonstone_manifest "${moonstone_case_dir}/app" "benchmark-dependencies" true

    env \
        HOME="${moonstone_case_dir}/home" \
        XDG_CONFIG_HOME="${moonstone_case_dir}/xdg-config" \
        XDG_DATA_HOME="${moonstone_case_dir}/xdg-data" \
        XDG_CACHE_HOME="${moonstone_case_dir}/xdg-cache" \
        MOONSTONE_HOME="${moonstone_case_dir}/moonstone-home" \
        MOONSTONE_CONFIG="${moonstone_case_dir}/moonstone-config" \
        MOONSTONE_DATA="${moonstone_case_dir}/moonstone-data" \
        MOONSTONE_CACHE="${moonstone_case_dir}/moonstone-cache" \
        bash -c 'set -euo pipefail; cd "$1"; moon sync --jobs "$2" --progress plain >/dev/null' -- \
        "${moonstone_case_dir}/runtime" "${moonstone_jobs}"

    run_timed dependencies moonstone "${run}" env \
        HOME="${moonstone_case_dir}/home" \
        XDG_CONFIG_HOME="${moonstone_case_dir}/xdg-config" \
        XDG_DATA_HOME="${moonstone_case_dir}/xdg-data" \
        XDG_CACHE_HOME="${moonstone_case_dir}/xdg-cache" \
        MOONSTONE_HOME="${moonstone_case_dir}/moonstone-home" \
        MOONSTONE_CONFIG="${moonstone_case_dir}/moonstone-config" \
        MOONSTONE_DATA="${moonstone_case_dir}/moonstone-data" \
        MOONSTONE_CACHE="${moonstone_case_dir}/moonstone-cache" \
        bash -c 'set -euo pipefail; cd "$1"; moon sync --jobs "$2" --progress plain; moon run verify -- --json >/dev/null' -- \
        "${moonstone_case_dir}/app" "${moonstone_jobs}"
}

run_moonstone_locked_replay() {
    local run="$1"
    make_case_dir locked-replay moonstone "${run}"
    local moonstone_case_dir="${case_dir}"
    write_moonstone_manifest "${moonstone_case_dir}/app" "benchmark-locked-replay" true

    env \
        HOME="${moonstone_case_dir}/home" \
        XDG_CONFIG_HOME="${moonstone_case_dir}/xdg-config" \
        XDG_DATA_HOME="${moonstone_case_dir}/xdg-data" \
        XDG_CACHE_HOME="${moonstone_case_dir}/xdg-cache" \
        MOONSTONE_HOME="${moonstone_case_dir}/moonstone-home" \
        MOONSTONE_CONFIG="${moonstone_case_dir}/moonstone-config" \
        MOONSTONE_DATA="${moonstone_case_dir}/moonstone-data" \
        MOONSTONE_CACHE="${moonstone_case_dir}/moonstone-cache" \
        bash -c 'set -euo pipefail; cd "$1"; moon sync --jobs "$2" --progress plain >/dev/null; rm -rf .moonstone/env' -- \
        "${moonstone_case_dir}/app" "${moonstone_jobs}"

    run_timed locked-replay moonstone "${run}" env \
        HOME="${moonstone_case_dir}/home" \
        XDG_CONFIG_HOME="${moonstone_case_dir}/xdg-config" \
        XDG_DATA_HOME="${moonstone_case_dir}/xdg-data" \
        XDG_CACHE_HOME="${moonstone_case_dir}/xdg-cache" \
        MOONSTONE_HOME="${moonstone_case_dir}/moonstone-home" \
        MOONSTONE_CONFIG="${moonstone_case_dir}/moonstone-config" \
        MOONSTONE_DATA="${moonstone_case_dir}/moonstone-data" \
        MOONSTONE_CACHE="${moonstone_case_dir}/moonstone-cache" \
        bash -c 'set -euo pipefail; cd "$1"; moon sync --locked --offline --jobs "$2" --progress plain' -- \
        "${moonstone_case_dir}/app" "${moonstone_jobs}"

    env \
        HOME="${moonstone_case_dir}/home" \
        XDG_CONFIG_HOME="${moonstone_case_dir}/xdg-config" \
        XDG_DATA_HOME="${moonstone_case_dir}/xdg-data" \
        XDG_CACHE_HOME="${moonstone_case_dir}/xdg-cache" \
        MOONSTONE_HOME="${moonstone_case_dir}/moonstone-home" \
        MOONSTONE_CONFIG="${moonstone_case_dir}/moonstone-config" \
        MOONSTONE_DATA="${moonstone_case_dir}/moonstone-data" \
        MOONSTONE_CACHE="${moonstone_case_dir}/moonstone-cache" \
        bash -c 'set -euo pipefail; cd "$1"; moon run verify -- --json >/dev/null' -- \
        "${moonstone_case_dir}/app"
}

run_luarocks() {
    local suite="$1"
    local run="$2"
    make_case_dir "${suite}" luarocks "${run}"
    local luarocks_case_dir="${case_dir}"
    local tree="${luarocks_case_dir}/tree"

    run_timed "${suite}" luarocks "${run}" env \
        HOME="${luarocks_case_dir}/home" \
        XDG_CONFIG_HOME="${luarocks_case_dir}/xdg-config" \
        XDG_DATA_HOME="${luarocks_case_dir}/xdg-data" \
        XDG_CACHE_HOME="${luarocks_case_dir}/xdg-cache" \
        bash -c '
            set -euo pipefail
            tree="$1"
            demo="$2"
            shift 2
            for rock in "$@"; do
                read -r name version <<<"${rock}"
                lua5.4 /usr/bin/luarocks --lua-version=5.4 --tree="${tree}" install "${name}" "${version}"
            done
            LUA_PATH="${tree}/share/lua/5.4/?.lua;${tree}/share/lua/5.4/?/init.lua;;" \
            LUA_CPATH="${tree}/lib/lua/5.4/?.so;;" \
            lua5.4 "${demo}/src/verify.lua" --json >/dev/null
        ' -- "${tree}" "${demo_source}" "${rocks[@]}"
}

median() {
    sort -n | awk '
        { values[NR] = $1 }
        END {
            if (NR == 0) exit 1
            middle = int((NR + 1) / 2)
            if (NR % 2 == 1) print values[middle]
            else print (values[middle] + values[middle + 1]) / 2
        }
    '
}

summarize() {
    local suite="$1"
    local tool="$2"
    local median_seconds
    median_seconds="$(jq -r --arg suite "${suite}" --arg tool "${tool}" 'select(.suite == $suite and .tool == $tool) | .elapsed_seconds' "${report_dir}/results.ndjson" | median)"
    printf '%-14s %-12s %8ss median\n' "${suite}" "${tool}" "${median_seconds}"
}

run_paired_suite() {
    local suite="$1"
    local run
    for run in $(seq 1 "${run_count}"); do
        if (( run % 2 == 1 )); then
            "run_moonstone_${suite}" "${run}"
            run_luarocks "${suite}" "${run}"
        else
            run_luarocks "${suite}" "${run}"
            "run_moonstone_${suite}" "${run}"
        fi
    done
    summarize "${suite}" moonstone
    summarize "${suite}" luarocks
}

run_locked_replay_suite() {
    local run
    for run in $(seq 1 "${run_count}"); do
        run_moonstone_locked_replay "${run}"
    done
    summarize locked-replay moonstone
}

case "${benchmark_suite}" in
    clean|dependencies|locked-replay|all) ;;
    *) echo "ERROR: BENCHMARK_SUITE must be clean, dependencies, locked-replay, or all" >&2; exit 64 ;;
esac

mkdir -p "${report_dir}"
: >"${report_dir}/results.ndjson"

echo "LuaRocks vs Moonstone benchmark"
echo "Suite: ${benchmark_suite}; runs: ${run_count}; Moonstone jobs: ${moonstone_jobs}; Moonstone build: ${MOONSTONE_BENCHMARK_BUILD_MODE:-unknown}"

if [[ "${benchmark_suite}" == "clean" || "${benchmark_suite}" == "all" ]]; then
    run_paired_suite clean
fi
if [[ "${benchmark_suite}" == "dependencies" || "${benchmark_suite}" == "all" ]]; then
    run_paired_suite dependencies
fi
if [[ "${benchmark_suite}" == "locked-replay" || "${benchmark_suite}" == "all" ]]; then
    run_locked_replay_suite
fi

echo "Raw result records: ${report_dir}/results.ndjson"
