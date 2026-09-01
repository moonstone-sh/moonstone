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
trap 'rm -rf "${WORKDIR}"' EXIT
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

# Simulate a cache created by the pre-contract store-manifest writer. The next
# add must hydrate the exact remote descriptor rather than silently locking
# only the direct package.
root_manifest="$(find "${MOONSTONE_HOME}/data/store" -path '*example/root-1.0.0/manifest.toml' -print -quit)"
test -n "${root_manifest}"
perl -0pi -e 's/\n\[\[dependencies\]\][\s\S]*\z/\n/' "${root_manifest}"

LEGACY_PROJECT="${WORKDIR}/legacy-project"
mkdir -p "${LEGACY_PROJECT}"
cd "${LEGACY_PROJECT}"
moon init . --name legacy-transitive-registry-closure --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon registry add local "file://${REGISTRY}"
moon add "local:example/root@1.0.0" --jobs 1
grep -q 'name = "example/middle"' moonstone.lock
grep -q 'name = "example/leaf"' moonstone.lock

echo "✓ moon add reconciles complete transitive registry closure"
