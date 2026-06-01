# Negative Test Matrix

This matrix tracks failure-mode coverage for Moonstone commands, with emphasis on resolver, network, protocol, and mutation-safety behavior.

## Goals

- Fail loudly with actionable plain-text errors.
- Emit valid NDJSON with a terminal `ERROR` message under `--json`.
- Preserve root causes instead of collapsing network/protocol failures into generic package misses.
- Avoid partial `moonstone.toml`, `moonstone.lock`, or `.moonstone/env` mutation after failed commands.
- Keep fallback behavior intentional: missing candidates may fall through to another resolver, but transport/protocol failures should not be swallowed for explicit resolvers such as `rocks:`.

## Coverage Matrix

| Area | Case | Expected Behavior | Current Coverage |
|---|---|---|---|
| LuaRocks network | Refused/unreachable endpoint | `RocksVersionDiscoveryFailed`, no manifest mutation, JSON terminator | `fixtures/tests/commands/10-luarocks-negative-network.sh` |
| LuaRocks network | Manifest HTTP 404 | `RocksVersionDiscoveryFailed`, no manifest mutation, JSON terminator | `fixtures/tests/commands/11-luarocks-negative-mock-manifests.sh` |
| LuaRocks network | Manifest HTTP 500 | `RocksVersionDiscoveryFailed`, no manifest mutation, JSON terminator | `fixtures/tests/commands/11-luarocks-negative-mock-manifests.sh` |
| LuaRocks network | Invalid manifest JSON | `RocksVersionDiscoveryFailed`, no manifest mutation, JSON terminator | `fixtures/tests/commands/11-luarocks-negative-mock-manifests.sh` |
| LuaRocks metadata | Manifest missing `repository` | `RocksVersionDiscoveryFailed` or more specific metadata error | Planned |
| LuaRocks metadata | Package absent from manifest | `PackageNotFound`; explicit `rocks:` does not mutate manifest | Planned |
| LuaRocks metadata | Version present but no usable rockspec | `RockspecNotFound`; no manifest mutation | Planned |
| LuaRocks metadata | Malformed rockspec | Structured parse error; no manifest mutation | Planned |
| Compatibility | Lua ABI mismatch | No stale env/lock reuse; clear resolver failure | `fixtures/scenario-tests/23-use-abi-change.sh` |
| Compatibility | Unsupported binary arch | Fall back to source where possible, otherwise clear unsupported error | Planned |
| Compatibility | Unsupported build type | `UnsupportedLuaRocksBuildType`; no manifest mutation | Planned |
| Materialization | Source download fails | Materializer/download error with package context | Planned |
| Materialization | Hash mismatch | Structured `hash_mismatch`; no env replacement | Planned |
| Runtime | Missing runtime parser for rockspec | Runtime-required error with `moon use` guidance | Planned |
| Runtime | Bad runtime executable path | Runtime-required error with concrete path | Planned |
| Store/offline | Cached rocks artifact missing transitive dep | `OfflineTransitiveArtifactMissing` with parent/child/resolver/constraint details; lock/env unchanged | `fixtures/scenario-tests/26-rocks-transitive-offline-missing-child.sh` (plain text + JSON diagnostic assertions) |
| Store/offline | Locked replay artifact missing from store | `LockedArtifactMissing` with `locked_artifact_missing` diagnostic (name, version, resolver, expected hash); lock/env unchanged | Covered by `install --locked` path; `graph_provider.getArtifact` enforces strict hash identity gate |
| Store/offline | Offline install with complete store cache | Resolves entirely from store; no network | `fixtures/scenario-tests/25-rocks-transitive-offline.sh` |
| Mutation safety | Failed `moon add rocks:...` | `moonstone.toml` unchanged | Covered for refused endpoint; expand to all negative cases |
| Mutation safety | Failed `moon sync` | Existing valid lock/env remains intact | Planned |
| Protocol | JSON negative path | Valid NDJSON, final `terminator: true`, stable `value` | Covered for refused endpoint; expand to all negative cases |
| Protocol | Retry reporting | Retry attempts emit `WARN` in JSON and readable retry text in plain mode | Planned |
| Doctor | LuaRocks unreachable | `moon doctor` warns without failing unrelated checks | Planned |

## Implementation Notes

- Prefer contract tests for command/protocol/mutation behavior.
- Prefer scenario tests for multi-step resolver/materializer flows.
- Use the Python LuaRocks mock server modes for deterministic HTTP failure responses; `testing-suite/run_lua_tool.sh generate-mock-rocks` dispatches to it directly so rocks tests do not depend on real LuaRocks bootstrap.
- Keep tests deterministic by setting `[network] retries = 0` unless the test is explicitly about retry behavior.
