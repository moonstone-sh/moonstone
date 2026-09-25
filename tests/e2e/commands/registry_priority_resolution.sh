#!/usr/bin/env bash
set -euo pipefail

# Guards the 0.5.8 registry-resolution fixes found while debugging
# hydronium's CI consumer gate:
#
#  1. An unprefixed package spec (`moon add example/pkg`, no `name:`
#     prefix) must consult EVERY registry of the moonstone resolver kind
#     declared in moonstone.toml, in descending priority order -- not
#     silently pin to whichever registry happens to be named "moonstone".
#  2. A transitive dependency declared in a registry descriptor with only
#     `resolver = "moonstone"` (no specific registry pinned) must resolve
#     the same way: by priority across every moonstone-kind registry, not
#     get pinned to a registry literally named "moonstone".
#  3. Two registries declared at the same priority resolve deterministically,
#     by their declaration order in moonstone.toml (first declared wins).
#  4. An explicit `name:` prefix still pins to exactly that registry,
#     regardless of any other registry's priority.
#  5. None of the above changes `moon sync --locked` on a project with a
#     pre-existing lock: the exact registry recorded in the lock keeps being
#     used, even if a newer, higher-priority registry is added later.

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-registry-priority.XXXXXX)"
cleanup() {
    if [[ "${MOONSTONE_KEEP_TEST_WORKDIR:-0}" != "1" ]]; then
        rm -rf "${WORKDIR}"
    fi
}
trap cleanup EXIT

# Publishes a single-file source package `${name}@${version}` to the local
# file registry at `${reg}`, optionally with one runtime dependency declared
# the way a real moonstone-kind registry descriptor declares an unpinned
# dependency: `resolver = "moonstone"`, no `registry` field at all.
publish() {
    local reg="$1" name="$2" version="$3" dependency="${4:-}"
    local tag
    tag="$(echo "${name}-${version}" | tr '/' '_')"
    local package_dir="${WORKDIR}/src-${tag}"
    local descriptor="${WORKDIR}/${tag}.toml"
    local blob="${WORKDIR}/${tag}.tar.gz"

    mkdir -p "${package_dir}"
    printf 'return %q\n' "${name}@${version}" >"${package_dir}/mod.lua"
    tar -czf "${blob}" -C "${package_dir}" .

    cat >"${descriptor}" <<EOF
[package]
name = "${name}"
version = "${version}"
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
resolver = "moonstone"
EOF
    fi

    moon registry push "${reg}" --descriptor "${descriptor}" --blob "${blob}" >/dev/null
}

# Reads one `key = "value"` field out of the moonstone.lock `[[package]]`
# block whose `name = "<pkg>"` line matches exactly, up to the next blank
# line. Prints the unquoted value, or nothing if not found.
lock_field() {
    local pkg="$1" field="$2" file="${3:-moonstone.lock}"
    awk -v pkg="${pkg}" -v field="${field}" '
        $0 == "name = \"" pkg "\"" { f=1; next }
        f && $0 == "" { f=0 }
        f && index($0, field " = \"") == 1 {
            line = $0
            sub("^" field " = \"", "", line)
            sub("\"$", "", line)
            print line
            exit
        }
    ' "${file}"
}

# ─── Part 1: unprefixed add + transitive dep resolve by priority ───────────

REG_LOW="${WORKDIR}/registry-low"
REG_HIGH="${WORKDIR}/registry-high"
moon registry create "${REG_LOW}" local >/dev/null
moon registry create "${REG_HIGH}" local >/dev/null

# Same package name published at different versions to each registry, so a
# resolved version unambiguously identifies which registry actually served
# the request.
publish "${REG_LOW}" "example/leaf" "1.0.0"
publish "${REG_HIGH}" "example/leaf" "1.5.0"
# "example/root" depends on "example/leaf" with no registry pinned at all,
# exactly like an ordinary registry-published dependency.
publish "${REG_LOW}" "example/root" "1.0.0" "example/leaf"

PROJECT="${WORKDIR}/project"
mkdir -p "${PROJECT}"
cd "${PROJECT}"
moon init . --name registry-priority-test --no-git --no-sync >/dev/null
moon interpreter set lua@5.4 --no-sync >/dev/null
moon registry add low "file://${REG_LOW}" >/dev/null
# --default: highest priority in the project (bug #3's fix). Also exercises
# that flag doing something, rather than being parsed and silently ignored.
moon registry add high "file://${REG_HIGH}" --default >/dev/null

grep -Fq 'path = "/' moonstone.toml
if grep -Fq 'path = "//' moonstone.toml; then
    echo "✗ file:// registry path retained an extra leading slash (see registry_add.zig)" >&2
    grep 'path = ' moonstone.toml >&2
    exit 1
fi
grep -A3 'name = "high"' moonstone.toml | grep -Fq 'priority = 1'

# Unprefixed root dependency: must resolve from the local "low" registry
# (the only one that has it), and its unprefixed transitive "example/leaf"
# dependency must resolve from "high" (priority 1), NOT "low" (priority 0),
# even though "low" also has a satisfying version.
moon add "low:example/root@1.0.0" --jobs 1 >/dev/null

leaf_version="$(lock_field "example/leaf" "version")"
leaf_registry="$(lock_field "example/leaf" "registry")"
if [[ "${leaf_version}" != "1.5.0" ]]; then
    echo "✗ expected unprefixed transitive example/leaf to resolve 1.5.0 from the higher-priority registry, got ${leaf_version}" >&2
    exit 1
fi
if [[ "${leaf_registry}" != "high" ]]; then
    echo "✗ expected unprefixed transitive example/leaf to be recorded as resolved from registry 'high', got '${leaf_registry}'" >&2
    exit 1
fi
echo "✓ unprefixed transitive dependency resolved from the higher-priority registry (1.5.0 from 'high')"

# ─── Part 2: equal priority resolves by declaration order ──────────────────

REG_FIRST="${WORKDIR}/registry-first"
REG_SECOND="${WORKDIR}/registry-second"
moon registry create "${REG_FIRST}" local >/dev/null
moon registry create "${REG_SECOND}" local >/dev/null
# Both registries publish the SAME version number. PubGrub's version
# selection is by semver, independent of registry priority -- if the two
# registries offered different version numbers, the solver would pick
# whichever is numerically newest regardless of registry order, which
# wouldn't test the tie-break at all. With an identical version on both
# sides, `getVersions` de-duplicates it to a single candidate, so which
# registry's copy of that candidate wins is decided purely by which
# registry `get_artifact`/`getVersions` consult first -- exactly the
# declaration-order tie-break under test.
publish "${REG_FIRST}" "example/tiebreak" "1.0.0"
publish "${REG_SECOND}" "example/tiebreak" "1.0.0"

TIEBREAK_PROJECT="${WORKDIR}/tiebreak-project"
mkdir -p "${TIEBREAK_PROJECT}"
cd "${TIEBREAK_PROJECT}"
moon init . --name registry-tiebreak-test --no-git --no-sync >/dev/null
moon interpreter set lua@5.4 --no-sync >/dev/null
# Both declared at the default priority (0): "first" is added -- and thus
# declared -- before "second".
moon registry add first "file://${REG_FIRST}" >/dev/null
moon registry add second "file://${REG_SECOND}" >/dev/null
first_line="$(grep -n 'name = "first"' moonstone.toml | head -1 | cut -d: -f1)"
second_line="$(grep -n 'name = "second"' moonstone.toml | head -1 | cut -d: -f1)"
if (( second_line < first_line )); then
    echo "✗ expected moonstone.toml to preserve declaration order (first before second) after 'registry add'" >&2
    exit 1
fi

moon add example/tiebreak --jobs 1 >/dev/null
tiebreak_registry="$(lock_field "example/tiebreak" "registry")"
if [[ "${tiebreak_registry}" != "first" ]]; then
    echo "✗ expected the earlier-declared, equal-priority registry ('first') to win, got '${tiebreak_registry}'" >&2
    exit 1
fi
echo "✓ equal-priority registries resolve by declaration order ('first' won)"

# ─── Part 3: an explicit prefix still pins to exactly that registry ────────

cd "${PROJECT}"
# "low" has example/leaf@1.0.0; "high" (higher priority) has 1.5.0. An
# explicit "low:" prefix must still resolve 1.0.0 from "low", regardless of
# "high" outranking it.
moon add "low:example/leaf@1.0.0" --jobs 1 >/dev/null
pinned_version="$(lock_field "example/leaf" "version")"
pinned_registry="$(lock_field "example/leaf" "registry")"
if [[ "${pinned_version}" != "1.0.0" || "${pinned_registry}" != "low" ]]; then
    echo "✗ expected explicit 'low:' prefix to pin example/leaf to 1.0.0 from 'low', got ${pinned_version} from '${pinned_registry}'" >&2
    exit 1
fi
echo "✓ explicit 'name:' prefix still pins to exactly that registry, ignoring priority"

# ─── Part 4: existing lock is stable under `sync --locked` ─────────────────

# A fresh UNPREFIXED dependency, resolved while only "low" carries it, so
# the lock's recorded registry comes entirely from priority-ordered
# discovery, not from any explicit pin in moonstone.toml -- this is exactly
# the shape of dependency the bug fix changes how it resolves. Adding a
# newer, higher-priority registry that also carries a satisfying version
# afterward must NOT change what a locked sync replays.
publish "${REG_LOW}" "example/stable" "1.0.0"
moon add example/stable --jobs 1 >/dev/null
stable_version="$(lock_field "example/stable" "version")"
stable_registry="$(lock_field "example/stable" "registry")"
if [[ "${stable_version}" != "1.0.0" || "${stable_registry}" != "low" ]]; then
    echo "✗ expected unprefixed example/stable to resolve 1.0.0 from 'low' (the only registry that has it), got ${stable_version} from '${stable_registry}'" >&2
    exit 1
fi
if grep -A4 'name = "example/stable"' moonstone.toml | grep -q 'registry ='; then
    echo "✗ expected example/stable's moonstone.toml entry to have no registry pin (it was added unprefixed)" >&2
    exit 1
fi

REG_NEWER="${WORKDIR}/registry-newer"
moon registry create "${REG_NEWER}" local >/dev/null
publish "${REG_NEWER}" "example/stable" "9.9.9"
moon registry add newer "file://${REG_NEWER}" --default >/dev/null
grep -A3 'name = "newer"' moonstone.toml | grep -Fq 'priority = 2'

cp moonstone.lock "${WORKDIR}/moonstone.lock.before-locked-sync"
moon sync --locked >/dev/null
if ! diff -q "${WORKDIR}/moonstone.lock.before-locked-sync" moonstone.lock >/dev/null; then
    echo "✗ 'moon sync --locked' modified moonstone.lock; a locked sync must not re-resolve" >&2
    diff "${WORKDIR}/moonstone.lock.before-locked-sync" moonstone.lock >&2 || true
    exit 1
fi
relocked_version="$(lock_field "example/stable" "version")"
relocked_registry="$(lock_field "example/stable" "registry")"
if [[ "${relocked_version}" != "1.0.0" || "${relocked_registry}" != "low" ]]; then
    echo "✗ 'moon sync --locked' should keep replaying the locked example/stable 1.0.0 from 'low', got ${relocked_version} from '${relocked_registry}'" >&2
    exit 1
fi
echo "✓ 'moon sync --locked' is unaffected by a newer, higher-priority registry (existing locks stay stable)"

echo "━━━ ✓ Registry priority resolution passed ━━━"
