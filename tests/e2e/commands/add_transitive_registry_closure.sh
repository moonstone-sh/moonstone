#!/usr/bin/env bash
set -euo pipefail

# `moon add` must produce a complete lock/profile closure even when the first
# direct package is materialized before sync runs. This specifically guards the
# local-store reconciliation path used by the normal (non---update) policy.

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-add-transitive-closure.XXXXXX)"
cleanup() {
    if [[ "${MOONSTONE_KEEP_TEST_WORKDIR:-0}" != "1" ]]; then
        rm -rf "${WORKDIR}"
    fi
}
trap cleanup EXIT
REGISTRY="${WORKDIR}/registry"
PROJECT="${WORKDIR}/project"

publish() {
    local name="$1"
    local dependency="${2:-}"
    local package_dir="${WORKDIR}/${name##*/}"
    local descriptor="${WORKDIR}/${name##*/}.toml"
    local blob="${WORKDIR}/${name##*/}.tar.gz"

    mkdir -p "${package_dir}"
    printf 'return %q\n' "${name}" >"${package_dir}/${name##*/}.lua"
    tar -czf "${blob}" -C "${package_dir}" .

    cat >"${descriptor}" <<EOF
[package]
name = "${name}"
version = "1.0.0"
kind = "lib"

[[artifacts]]
id = "source"
kind = "source"
target = "source"
format = "tar.gz"
url = "placeholder.tar.gz"
hash = "b3:placeholder"

[artifacts.materialize]
type = "archive"
EOF

    if [[ -n "${dependency}" ]]; then
        cat >>"${descriptor}" <<EOF

[[dependencies]]
name = "${dependency}"
constraint = "^1.0.0"
role = "runtime"
EOF
    fi

    moon registry push "${REGISTRY}" --descriptor "${descriptor}" --blob "${blob}"
}

moon registry create "${REGISTRY}" local
publish "example/leaf"
publish "example/middle" "example/leaf"
publish "example/root" "example/middle"

mkdir -p "${PROJECT}"
cd "${PROJECT}"
moon init . --name transitive-registry-closure --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon registry add local "file://${REGISTRY}"
moon add "local:example/root@1.0.0" --jobs 1

grep -q 'name = "example/root"' moonstone.lock
grep -q 'name = "example/middle"' moonstone.lock
grep -q 'name = "example/leaf"' moonstone.lock

# Locked replay must retrieve the exact recorded registry artifact after its
# CAS directory disappears and reproduce the same output identity.
root_manifest="$(find "${MOONSTONE_HOME}/data/store" -path '*example/root-1.0.0/manifest.toml' -print -quit)"
test -n "${root_manifest}"
locked_root_hash="$(awk '/name = "example\/root"/{found=1} found && /artifact_hash =/{gsub(/[\" ]/, "", $3); print $3; exit}' moonstone.lock)"
rm -rf "$(dirname "${root_manifest}")" .moonstone/env
moon sync --locked
restored_manifest="$(find "${MOONSTONE_HOME}/data/store" -path '*example/root-1.0.0/manifest.toml' -print -quit)"
grep -q "^artifact_hash = \"${locked_root_hash}\"$" "${restored_manifest}"

# A fresh consumer must see the same closure from the now-populated store.
# Incomplete legacy metadata is covered by provider unit fixtures, without
# mutating admitted CAS artifacts.
CACHED_PROJECT="${WORKDIR}/cached-project"
mkdir -p "${CACHED_PROJECT}"
cd "${CACHED_PROJECT}"
moon init . --name cached-transitive-registry-closure --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon registry add local "file://${REGISTRY}"
moon add "local:example/root@1.0.0" --jobs 1
grep -q 'name = "example/middle"' moonstone.lock
grep -q 'name = "example/leaf"' moonstone.lock
moon sync --offline

echo "✓ moon add reconciles complete transitive registry closure"
