#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOON="${MOON_BIN:-${ROOT}/zig-out/bin/moon}"
WORK="$(mktemp -d /tmp/moon-runtime-commands.XXXXXX)"
trap 'if [[ ${KEEP_WORK:-0} == 1 ]]; then echo "Fixture: $WORK"; else rm -rf "$WORK"; fi' EXIT
export MOONSTONE_HOME="$WORK/home"
export MOONSTONE_NO_PROGRESS=1
mkdir -p "$WORK/project" "$WORK/source/bin"
printf '#!/bin/sh\nprintf "fixture runtime\\n"\n' > "$WORK/source/bin/lua"
chmod +x "$WORK/source/bin/lua"
tar -czf "$WORK/runtime.tar.gz" -C "$WORK/source" .
"$MOON" registry init --file "$WORK/registry" --name runtimes >/dev/null
publish_runtime() {
    local name=$1 version=$2 abi=$3
    printf '#!/bin/sh\nprintf "%s %s\\n"\n' "$name" "$version" > "$WORK/source/bin/lua"
    chmod +x "$WORK/source/bin/lua"
    tar -czf "$WORK/runtime.tar.gz" -C "$WORK/source" .
    cat > "$WORK/package.toml" <<TOML
[package]
name = "moonstone/$name"
version = "$version"
kind = "runtime"
[[artifacts]]
id = "any"
kind = "runtime"
target = "any"
lua_abi = "$abi"
format = "tar.gz"
url = "placeholder.tar.gz"
hash = "b3:placeholder"
[artifacts.materialize]
type = "archive"
[[artifacts.provides]]
kind = "runtime"
name = "$name"
version = "$version"
lua_abi = "$abi"
[[artifacts.provides]]
kind = "bin"
name = "lua"
path = "bin/lua"
TOML
    "$MOON" registry --file "$WORK/registry" publish --descriptor "$WORK/package.toml" --artifact "$WORK/runtime.tar.gz" >/dev/null
}
publish_runtime lua 5.4.123 5.4
publish_runtime luajit 2.1.0-beta3 5.1
"$MOON" add --global lua@5.4.123 --registry "file://$WORK/registry" --json > "$WORK/install.jsonl"
python3 - "$WORK/install.jsonl" <<'PY'
import sys,json
rows=[json.loads(line) for line in open(sys.argv[1])]
assert rows[-1]['terminator'] and rows[-1]['kind']=='RESULT'
PY
"$MOON" add --global luajit@2.1.0-beta3 --registry "file://$WORK/registry" >/dev/null
cd "$WORK/project"
"$MOON" init . --name runtime-contract --interpreter lua@5.4.123 --no-sync --no-git >/dev/null
"$MOON" set luajit@2.1.0-beta3 --no-sync --json > "$WORK/set.jsonl"
grep -q 'name = "luajit"' moonstone.toml
grep -q 'abi = "5.1"' moonstone.toml
if "$MOON" remove luajit --no-sync > "$WORK/primary-remove.log" 2>&1; then
    echo 'Project removal silently replaced the primary runtime' >&2; exit 1
fi
grep -q 'moon set' "$WORK/primary-remove.log"
"$MOON" set --global luajit@2.1.0-beta3 --json > "$WORK/global.jsonl"
# The shared TOML editor creates the config even in a fresh home.
"$MOON" config show > "$WORK/config-paths"
config_file=$(sed -n 's/^ *Config File: *//p' "$WORK/config-paths")
grep -q 'default_runtime = "luajit-2.1.0-beta3"' "$config_file"
if "$MOON" remove --global luajit@2.1.0-beta3 --json > "$WORK/blocked.jsonl"; then
    echo 'Removed a globally selected runtime' >&2; exit 1
fi
grep -q 'InterpreterStillReferenced' "$WORK/blocked.jsonl"
"$MOON" set --global lua@5.4.123 >/dev/null
"$MOON" sync > "$WORK/sync.log" 2>&1 || { cat "$WORK/sync.log"; exit 1; }
if "$MOON" remove --global luajit@2.1.0-beta3 --json > "$WORK/project-blocked.jsonl"; then
    echo 'Removed a project-referenced runtime' >&2; exit 1
fi
grep -q 'InterpreterStillReferenced' "$WORK/project-blocked.jsonl"
protected_hash=$(sed -n 's/^artifact_hash = "\(.*\)"/\1/p' moonstone.lock | head -1)
"$MOON" store prune --dry-run > "$WORK/prune.log"
if grep -Fq "Would GC: $protected_hash" "$WORK/prune.log"; then
    echo 'Prune ignored the registered project lock' >&2; exit 1
fi
"$MOON" set lua@5.4.123 >/dev/null
# Retained lock profiles still own their runtimes after switching the active one.
if "$MOON" remove --global luajit@2.1.0-beta3 --json > "$WORK/profile-blocked.jsonl"; then
    echo 'Removed a runtime retained by a lock profile' >&2; exit 1
fi
# Dispose of the complete fixture project; there are now no project references.
cd "$WORK"
rm -rf "$WORK/project"
"$MOON" remove --global luajit@2.1.0-beta3 --json > "$WORK/removed.jsonl"
"$MOON" store list --interpreters > "$WORK/installed"
if grep -q '2.1.0-beta3' "$WORK/installed"; then echo 'Removed runtime remains indexed' >&2; exit 1; fi
if "$MOON" interpreter set lua@5.4 --no-sync > /dev/null 2>&1; then echo 'Old interpreter group remains public' >&2; exit 1; fi
env MOONSTONE_HOME="$WORK/dry-run-home" "$MOON" add --global lua@5.4 --dry-run --json > "$WORK/plan.jsonl"
test ! -e "$WORK/dry-run-home"
if "$MOON" add --global lua@5.4 moonstone/ballad --dry-run > /dev/null 2>&1; then echo 'Mixed global runtime mutation accepted' >&2; exit 1; fi
printf 'Runtime command consolidation passed\n'
