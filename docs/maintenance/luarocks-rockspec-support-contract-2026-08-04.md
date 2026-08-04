# LuaRocks Rockspec Support Contract

**Status:** August 4, 2026. This document describes the support boundary that
Moonstone currently tests. It is a contract for project authors, not a claim of
full LuaRocks compatibility.

## Guaranteed and Certified

| Rockspec shape | Moonstone behavior | Certification |
| --- | --- | --- |
| `build.type = "builtin"` or omitted, pure Lua modules | Fetch, resolve, materialize Lua files | Resolver and offline-rock scenarios |
| `builtin` C sources in `build.modules` | Translate to Moonstone native C-module materialization | `tests/e2e/build/luarocks_builtin_cmodule.sh` |
| `build.type = "make"` | Translate to the command materializer and project `[build.env]` | `tests/e2e/build/luarocks_make_env.sh` |
| LuaRocks dependencies | Resolve transitively with explicit `rocks:` provenance | Transitive/offline resolver scenarios |
| Source archives | Handle zip, tar, gzip, bzip2, xz, and `.rock` archive forms when required host tools exist | Resolver/materialization scenarios |

## Implemented, Not Yet Certified as a Stable Guarantee

| Rockspec shape | Current implementation | Before guarantee |
| --- | --- | --- |
| `build.type = "cmake"` | Translates to the CMake materializer | Dedicated fixture, replay test, and target matrix |
| `build.type = "command"` | Translates to the command materializer | Dedicated fixture, argument/environment contract, and replay test |
| Platform-specific rockspec branches | The bridge identifies `unix`, `macosx`, or `win32` | Cross-platform fixtures, including Windows CI |
| `external_dependencies` | Parsed for metadata | Explicit provisioning or rejection semantics |

## Deliberately Rejected

Unknown `build.type` values fail with `UnsupportedLuaRocksBuildType`. Moonstone
does not silently invoke LuaRocks itself as an opaque fallback, provision system
dependencies, or promise binary-rock compatibility without a materialization
and replay contract.

## Provenance and Diagnostics

`moonstone.lock` remains the record of resolved source, artifact, target, and
realization facts. A rockspec is authoring input; its semantic build path must
be visible through resolution/materialization diagnostics and is only promoted
to a supported guarantee once it has a deterministic fixture.

## Promotion Rule

To move an item into **Guaranteed and Certified**, add a local fixture that
proves parsing, resolution, materialization, lock replay, and failure diagnostics
for its target scope. Windows-specific paths additionally require the Windows
CI job to pass.
