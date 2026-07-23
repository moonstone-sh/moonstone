# Executable Scope Closure v1

**Date**: 2026-07-22  
**Status**: Implemented and Validated  
**Decision Record**: Active

---

## Architectural Decision

> A package executable runs with the complete resolved dependency closure declared by that package's store manifest. This rule is generic: it applies to every executable package and never special-cases Cyan, Teal, Ballad, or another tool.

### Accepted Invariants

- [x] **No tool-specific exceptions** — executable scopes are constructed from store-manifest dependencies, not executable names.  
  **Annotation:** Cyan exposed the gap; it is not part of the implementation contract.
- [x] **Roles remain project-facing** — a project dependency's `tool`/`runtime` role controls project projection, not whether a package can access its own manifest dependencies.  
  **Annotation:** This prevents build-tool closure requirements from polluting exported application runtime dependencies.
- [x] **Closure paths are deterministic** — owner artifact first, followed by a stable traversal of its declared dependencies.  
  **Annotation:** Later entries must not introduce resolution-dependent path ordering.
- [x] **ABI compatibility remains mandatory** — a scope may only include artifacts compatible with the executable's selected runtime.  
  **Annotation:** Closure construction must preserve existing Lua ABI checks rather than bypass them.
- [x] **LuaRocks install semantics are generic** — `build.install.lua` and standard `share/lua/<abi>` payloads remain supported independently of scope closure.  
  **Annotation:** This work is retained even after the example no longer needs direct dependency projection.

---

## Implementation Checklist

- [x] **1. Baseline the current scope builder**  
  **Annotation:** `bin-runtime/<name>/env.toml` previously used only owner provisions; the linker already receives the full resolved artifact list.

- [x] **2. Define closure traversal input and ownership**  
  **Annotation:** Store manifests provide dependency edges; the linker uses the resolved artifact list to select exact locked artifacts.

- [x] **3. Implement deterministic manifest closure traversal**  
  **Annotation:** The linker walks declared dependencies owner-first, detects cycles by artifact hash, deduplicates nodes, and fails when a resolved dependency is absent.

- [x] **4. Build executable scope paths from the closure**  
  **Annotation:** Every closure member contributes executable directories, Lua roots, and C-module roots; standard `share/lua/<abi>` payloads continue to project declarations into the project environment.

- [x] **5. Enforce runtime/ABI compatibility during traversal**  
  **Annotation:** Traversal rejects a resolved closure member whose declared Lua ABI differs from the executable owner ABI.

- [x] **6. Remove the Teal example projection workaround**  
  **Annotation:** The example no longer directly declares `luafilesystem` or `luasystem`; `argparse-tl-type` remains a tool-only type input.

- [x] **7. Add generic regression coverage**  
  **Annotation:** Linker tests assert dotted Lua and C-module provisions resolve to package Lua roots rather than duplicated dotted directories.

- [x] **8. Validate end-to-end examples and release behavior**  
  **Annotation:** `zig build test` passes. The Teal check/build/export workflow passes with the rebuilt CLI first on `PATH`, and Cyan loads its transitive `luafilesystem` and `luasystem` artifacts from its scope.

---

## Working Notes

- The Teal example declares application runtime dependencies separately from compiler type inputs. Cyan's native dependencies remain exclusively in Cyan's resolved executable closure.
- Current implementation work already corrected two independent LuaRocks compatibility gaps: builtin `build.install.lua` payloads were ignored, and linker fallback omitted standard `files/share/lua/<abi>` payload trees.
