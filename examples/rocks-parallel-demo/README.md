# Parallel LuaRocks Resolution Demo

This project makes Moonstone resolve and materialize a mix of independent
pure-Lua and native LuaRocks packages from the public LuaRocks registry.

It is intended to make the concurrent realization scheduler visible:

```text
resolve one dependency graph
→ identify dependency-ready materialization work
→ realize unrelated rocks concurrently
→ project one locked project environment
```

## Run Cold, Online Sync

From this directory, run:

```bash
./run-cold-sync.sh
```

The runner removes this example's local lock and environment, creates a fresh
Moonstone home under `/tmp`, then performs an online sync with up to eight
workers. It does not use your normal Moonstone cache or store.

Set `MOONSTONE_DEMO_JOBS` to compare worker limits:

```bash
MOONSTONE_DEMO_JOBS=1 ./run-cold-sync.sh
MOONSTONE_DEMO_JOBS=8 ./run-cold-sync.sh
```

Use `MOONSTONE_DEMO_HOME` if you want to retain the generated store and logs
after the script exits.

## Observe Structured Events

For automation or a more precise view of individual task transitions:

```bash
rm -rf .moonstone moonstone.lock
MOONSTONE_HOME="$(mktemp -d)/home" moon sync --jobs 8 --json
```

`--json` emits `moonstone:cli-events:v1` NDJSON. Each materialization task has
a stable identity and monotonic revision, so a viewer can replace a task's line
without losing its position.

## What It Installs

- Pure Lua: `ansicolors`, `argparse`, `dkjson`, `inspect`, `fun`, and `penlight`.
- Native or system-facing: `lpeg`, `luafilesystem`, and `luasocket`.

After syncing, run:

```bash
moon run verify
moon run verify -- --json
```

The example intentionally uses only ordinary public rocks. The first sync
depends on network access and the host C toolchain required by native rocks.
