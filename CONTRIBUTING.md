# Contributing to Moonstone

Thank you for taking the time to contribute to Moonstone.

Moonstone is a runtime-aware, content-addressed package and environment manager for Lua. The project cares about reproducibility, explicit runtime identity, air-gapped/private registry workflows, and clear failure modes. Contributions should preserve those goals.

## Current project status

Moonstone is currently pre-1.0 alpha. APIs, registry contracts, lockfile details, and CLI behavior may still evolve, but changes should be made deliberately and documented when they affect users.

Before making large changes, please open an issue or discussion describing the problem, the proposed direction, and any compatibility impact.

## Good first contributions

Useful contributions include:

- fixing documentation gaps or unclear examples
- improving diagnostics and error messages
- adding regression tests for existing behavior
- adding fixtures for registry, store, resolver, or runtime edge cases
- improving platform support without weakening reproducibility
- reporting bugs with clear reproduction steps

## Design principles

When contributing code, prefer solutions that follow these principles.

### Be explicit

Moonstone should avoid hidden global state where possible. Runtime, registry, artifact, and dependency identity should be explicit.

### Preserve reproducibility

A locked install should not silently substitute artifacts. Content hashes, runtime compatibility, and registry descriptors are part of Moonstone's trust model.

### Keep canonical data canonical

Registry TOML descriptors are the source of truth. SQLite indexes and other generated files are projections that should be rebuildable from canonical descriptors.

### Prefer safe failure modes

When Moonstone cannot prove that a runtime, package, artifact, or native module is compatible, it should fail with a useful diagnostic instead of guessing.

### Keep package identity stable

Package coordinates are supply-chain identity. Moves, deprecations, and yanks should be explicit and visible to the user.

## Development requirements

Moonstone is written primarily in Zig.

You will need:

- Zig matching the version declared by the project
- Git
- Python 3, for registry/testing tools
- a POSIX-like shell for scenario tests
- optional Docker, for isolated test runs

Check `build.zig.zon` and the project documentation for the exact Zig version and dependency expectations.

## Repository layout

The most important areas are:

```text
src/cli/                         CLI commands and routing
src/core/domain/                 manifests, lockfiles, package specs, semver
src/core/registry/               registry client and registry resolution
src/core/resolution/             coordinator, sources, provider, solver
src/core/materialization/        artifact materializers
src/core/store/                  local content-addressed store
src/core/luarocks/               LuaRocks bridge and rockspec handling
docs/                            architecture and registry contracts
fixtures/                        scenario and command fixtures
testing-suite/                   registry builders and integration tooling
release-tools/                   release packaging and publishing scripts
vendor/                          vendored third-party code
```

## Running tests

Start with:

```sh
zig build test
```

Then run the command contract tests:

```sh
./run_command_contract_tests.sh
```

For broader scenario coverage:

```sh
./run_all_synthetic_tests.sh
```

Some scenario tests may require network access, local registry fixtures, or platform-specific tooling. When reporting a failure, include the command you ran, your OS/architecture, Zig version, and relevant output.

## Before opening a pull request

Please run:

```sh
zig build test
./run_command_contract_tests.sh
```

If your change touches resolution, the store, registry descriptors, LuaRocks integration, runtimes, or materialization, also run:

```sh
./run_all_synthetic_tests.sh
```

Before publishing a branch or opening a pull request, check for accidental secrets:

```sh
git grep -n -I -E \
'(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]+|BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|password\s*=|token\s*=|secret\s*=|api[_-]?key\s*=|Authorization: Bearer)' \
-- ':!.git' ':!node_modules' ':!zig-cache' ':!.zig-cache' ':!zig-out' || true
```

Documentation examples may contain placeholders such as `<token>` or `mst_example_do_not_use`; real tokens must never be committed.

## Pull request checklist

A pull request should include:

- a clear summary of the change
- why the change is needed
- tests or fixtures for behavior changes
- documentation updates for user-facing changes
- notes about compatibility impact, if any
- confirmation that relevant tests were run

For user-visible behavior changes, include before/after examples when possible.

## Coding guidelines

### Zig style

- Prefer clear ownership and explicit deinitialization.
- Keep allocator ownership obvious.
- Avoid broad catch-all error handling that hides the real failure.
- Prefer precise errors and structured diagnostics.
- Keep parsing and normalization separate from execution when practical.
- Do not introduce hidden network access in offline or locked paths.

### File naming

Use `snake_case` for new source files unless there is an established local convention that says otherwise.

### Diagnostics

Moonstone errors should help users recover. A good diagnostic usually says:

1. what failed
2. which package/runtime/artifact/registry was involved
3. why Moonstone refused to continue
4. what the user can do next

For JSON/NDJSON output, keep machine-readable fields stable and avoid embedding essential information only in prose.

## Documentation guidelines

Documentation should be precise, but approachable.

When adding or changing docs:

- prefer concrete examples
- mark placeholders clearly
- avoid showing real-looking credentials
- distinguish alpha behavior from stable contracts
- update contract docs when registry, lockfile, descriptor, or CLI semantics change

Use fake tokens like:

```text
mst_example_do_not_use
```

Prefer environment-variable examples for private registry credentials:

```toml
[registries.company]
url = "https://registry.company.internal/v0"
token = "$MOONSTONE_COMPANY_TOKEN"
```

## Registry and package contract changes

Changes to registry descriptors, indexes, lockfiles, artifact identity, package movement, yanking, dependency encoding, or materialization semantics should be treated as contract changes.

For those changes, update the relevant docs, especially:

- `docs/REGISTRY_DESCRIPTOR_V0.md`
- `docs/REGISTRY_MODEL.md`
- `docs/ARCHITECTURE.md`

Also add or update fixtures when possible.

## Security issues

Please do not open public issues for suspected vulnerabilities.

Security-sensitive areas include:

- registry authentication
- publishing tokens
- private package access
- install script integrity
- artifact verification
- lockfile replay
- path traversal in registry/blob handling
- archive extraction
- native module materialization

Report security issues privately to the project maintainer or through the security contact listed in `SECURITY.md` once available.

## Licensing

By contributing, you agree that your contribution will be licensed under the Apache License 2.0, the same license as Moonstone.

Add SPDX headers to new source files when practical:

```zig
// SPDX-License-Identifier: Apache-2.0
```

Do not add third-party code unless its license is compatible with Apache-2.0 and the license is preserved. If you vendor or copy third-party code, document it in `THIRD_PARTY.md` or the appropriate notice file.

## Conduct

Be direct, technical, and respectful. Strong critique is welcome when it improves Moonstone, but keep discussions focused on the design, implementation, and user impact.
