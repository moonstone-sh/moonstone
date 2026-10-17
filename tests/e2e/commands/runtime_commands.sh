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
# Root-first workspace sync; each child remains an independent project.
"$MOON" init child --name workspace-child --interpreter lua@5.4.123 --no-sync --no-git >/dev/null
"$MOON" orbit add --name child --path child >/dev/null
"$MOON" sync --all --offline --json > "$WORK/workspace.log" 2>&1 || { cat "$WORK/workspace.log"; exit 1; }
test -f child/moonstone.lock
python3 - "$WORK/workspace.log" <<'PY_WORKSPACE'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1])]
assert sum(r['terminator'] for r in rows)==1
assert rows[-1]['value']=='workspace.complete'
assert [r['seq'] for r in rows]==list(range(1,len(rows)+1))
assert [r['data'].get('orbit') for r in rows if r['value']=='project.begin']==[None,'child']
PY_WORKSPACE
"$MOON" -C "$WORK/project" --orbit child exec -- lua > "$WORK/orbit-exec"
grep -q 'lua 5.4.123' "$WORK/orbit-exec"
if "$MOON" --orbit child sync --all > /dev/null 2>&1; then echo 'Conflicting workspace selection accepted' >&2; exit 1; fi
"$MOON" completions --complete "moon --orbit " | grep -Fx child
# Link registration and dependency removal never delete the source project.
"$MOON" -C child link >/dev/null
"$MOON" add link:workspace-child --no-sync >/dev/null
"$MOON" remove workspace-child --no-sync >/dev/null
if "$MOON" remove --global link:workspace-child link:missing > /dev/null 2>&1; then exit 1; fi
"$MOON" store list --links --json > "$WORK/links.jsonl"
grep -q workspace-child "$WORK/links.jsonl"
"$MOON" remove --global link:workspace-child --json > "$WORK/unlink.jsonl"
test -f child/moonstone.toml
# Exact selectors and fuzzy search share provenance-rich NDJSON output.
"$MOON" store list --query moonstone/lua --kind runtime --json > "$WORK/list.jsonl"
python3 - "$WORK/list.jsonl" <<'PY_LIST'
import sys,json
rows=[json.loads(line) for line in open(sys.argv[1])]
assert rows[0]['kind']=='START' and rows[-1]['terminator']
artifacts=[r['data'] for r in rows if r['kind']=='STATUS']
assert artifacts and all('source_hash' in r and 'warnings' in r for r in artifacts)
assert rows[-1]['data']['count']==len(artifacts)
PY_LIST
"$MOON" store prune --compact --dry-run > "$WORK/compact-plan"
if grep -q 'Index compacted' "$WORK/compact-plan"; then exit 1; fi
"$MOON" store prune --compact > "$WORK/compact"
grep -q 'Index compacted' "$WORK/compact"
for legacy in 'store query' 'index vacuum' 'orbit sync' 'orbit exec' 'orbit run'; do
    if "$MOON" $legacy > /dev/null 2>&1; then echo "Legacy command still public: $legacy" >&2; exit 1; fi
done
# Failure in a member stops before later members; --locked reaches children.
"$MOON" init blocked --name blocked-child --interpreter lua@5.4.123 --no-sync --no-git >/dev/null
"$MOON" init later --name later-child --interpreter lua@5.4.123 --no-sync --no-git >/dev/null
"$MOON" orbit add --name blocked --path blocked >/dev/null
"$MOON" orbit add --name later --path later >/dev/null
"$MOON" sync --offline > "$WORK/root-refresh.log" 2>&1
if "$MOON" sync --all --locked --offline > "$WORK/fail-fast.log" 2>&1; then echo 'Missing member lock ignored' >&2; exit 1; fi
grep -q "orbit 'blocked'" "$WORK/fail-fast.log"
test ! -f later/moonstone.lock
if "$MOON" sync --all --locked --offline --json > "$WORK/fail-fast.jsonl"; then exit 1; fi
python3 - "$WORK/fail-fast.jsonl" <<'PY_FAILURE'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1])]
assert sum(r['terminator'] for r in rows)==1
assert rows[-1]['kind']=='ERROR' and rows[-1]['data']['orbit']=='blocked'
assert [r['seq'] for r in rows]==list(range(1,len(rows)+1))
assert not any(r['value']=='workspace.complete' for r in rows)
PY_FAILURE
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
