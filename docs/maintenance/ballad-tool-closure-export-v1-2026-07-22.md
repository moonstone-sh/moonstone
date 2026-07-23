# Ballad Tool Closure Export v1

**Date**: 2026-07-22  
**Status**: Implemented and Validated  
**Decision Record**: Active

---

## Architectural Decision

> Ballad represents a Moonstone tool as a generic asset set derived from the tool's resolved executable scope. The asset set carries the tool executable, Lua sources, native modules, dependent executables, and runtime metadata without naming a particular package manager source or tool.

### Accepted Invariants

- [x] **Scope is authoritative** — Ballad reads the synchronized `bin-runtime/<tool>/env.toml` scope rather than reconstructing dependency resolution.
  **Annotation:** Moonstone owns resolution, lock replay, ABI checks, and artifact selection; Ballad consumes their deterministic result.
- [x] **Sources remain traceable** — tool assets preserve store-backed source paths and scope metadata.
  **Annotation:** Sinks and registry exporters can produce file graphs and provenance without opaque copies.
- [x] **The graph is tool-agnostic** — neither Cyan, Ballad, nor LuaRocks receive special node types.
  **Annotation:** A Moonstone registry tool and a `rocks:` tool share the same graph shape.
- [x] **Tool closure stays private** — packaging a tool does not promote its closure into a consuming application's runtime dependency set.
  **Annotation:** The output is an executable distribution of the tool itself.

---

## Implementation Checklist

- [x] **1. Add `moonstone.tool` graph input**  
  **Annotation:** A synchronized project tool resolves by executable name and emits an owner asset plus scope-derived source assets.
- [x] **2. Translate scope paths into assets**  
  **Annotation:** Lua roots, C-module roots, and PATH directories become deterministic `tool_source` assets with store-backed source paths.
- [x] **3. Teach executable layout to consume tools**  
  **Annotation:** `layout.exec` recognizes a tool node and emits a runnable libexec layout with `bin`, `lua`, and `lib` roots.
- [x] **4. Add generic tool export regression**  
  **Annotation:** `ballad/tests/test_tool_scope_exec.sh` exports a synthetic formatter with a Lua dependency and a native-module asset.
- [x] **5. Document user-facing tool behavior**  
  **Annotation:** Dependencies, custom-tool, and Ballad guides distinguish native registry and `rocks:` tools, explain closures, and show tool export.
- [x] **6. Validate graph, output, and documentation build**  
  **Annotation:** Tool-scope and existing executable-layout regressions pass; `moonstone.sh` `bun run build.types` passes.
