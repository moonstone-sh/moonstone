# Moonstone agent guide

This repository is the Zig runtime and package manager. Keep changes scoped to
Moonstone's deterministic model; do not edit generated environments, the CAS,
or lockfiles by hand.

## Start here

- User overview and first run: [`README.md`](README.md)
- Maintainer workflow: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Test commands and fixtures: [`TESTING.md`](TESTING.md)
- Architecture and contracts: [`docs/README.md`](docs/README.md)

## Workflow

```sh
zig build
./run-all-synthetic-tests.sh
```

For focused work, prefer the smallest scenario under `fixtures/scenario-tests/`
or `synthetic-tests/`, then run the relevant contract tests. LuaRocks behavior
belongs in the upstream/fixture suites and must preserve the distinction between
upstream versions, rock revisions, and exact lockfile artifacts.

Do not commit `.moonstone/`, build output, local registries, or generated test
homes. When a design note is complete, move it from `docs/maintenance/` to the
stable architecture/reference docs or mark it as historical.
