# Opaque Project Scripts — Accepted Architecture

**Status:** accepted breaking redesign, August 3, 2026.

`moonstone.toml` is human-authored project source. Moonstone's versioned
manifest and lock protocols are the machine-facing contracts.

```toml
[scripts]
build = "zig build -Doptimize=ReleaseFast"
release = "ballad build && ballad publish"
```

Each script has one stable name and one opaque command body. Script names use
`[A-Za-z0-9_-]+`. Moonstone finds the project, validates and projects the
resolved environment, then invokes the host shell. It does not parse commands,
translate shell syntax, own chaining, infer a command language, or become a
workflow engine. Multi-step portable orchestration belongs in Lua, Ballad, or
an explicitly invoked script file.

The documented host-shell mapping is non-interactive `sh -c` on macOS and
Linux, and `cmd /d /s /c` on Windows. Projects invoke PowerShell explicitly
when needed:

```toml
[scripts]
release-posix = "sh scripts/release.sh"
release-windows = "pwsh -NoProfile -File scripts/release.ps1"
release = "lua scripts/release.lua"
```

The project author owns portability. A simple command can remain inline;
substantial behavior belongs in ordinary source files or Ballad. Scripts remain
useful where a project wants a discoverable supported entrypoint:

```toml
[scripts]
dev = "lua scripts/dev.lua"
test = "lua scripts/test.lua"
release = "ballad release"
format = "stylua ."
```

`moon exec` is the primitive projected process runner and `moon run` invokes
one named entrypoint. `moon -C <project-dir> …` (or `moon --directory
<project-dir> …`) changes the project-resolution base before dispatch, so a
wrapper can call Moonstone reliably without changing the caller's directory:

```sh
#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec moon -C "$root" exec lua scripts/dev.lua "$@"
```

The semantic API is intentionally independent of TOML layout:

```text
moon manifest script list --json
moon manifest script get <name> --json
moon manifest script set <name> --command "zig build"
moon manifest script remove <name>
moon manifest export --json
moon manifest apply --json --force
moon manifest apply --json --dry-run
```

`manifest apply` remains transactional and conflict-aware. Its script operations
are `set_script` and `remove_script`; arbitrary TOML paths and generic JSON
Patch are not exposed. Ballad consumes these semantic contracts rather than
parsing or editing `moonstone.toml` directly.

The manifest-edit result reports whether a mutation was source-preserving or
canonicalized. Script-only edit batches preserve the `[scripts]` source region;
mixed-domain edits currently return `"storage_mode":"canonicalized"` so tools
can avoid claiming comment or formatting preservation beyond that boundary.

## Source-preserving script order

`[scripts]` is the first source-aware tidy domain. Its default policy is
lexicographic order by script name. `moon manifest script set`,
`moon manifest script remove`, and script-only `moon manifest apply` batches
apply that policy after their semantic edit; `moon manifest tidy` applies it on
demand and `moon manifest tidy --check` reports drift without writing.

The editor does not reconstruct unrelated manifest domains. Consecutive
comment-only lines directly preceding a script are a tied block comment and
move with that script. A trailing comment on the assignment line moves with it
as well. Comments separated by a blank line remain anchored in their original
table gap, rather than being silently assigned to a script. `moon manifest
tidy` warns about those `UnattachedManifestComment` lines; `--json` returns
them as structured diagnostics. Automatic script edits preserve them quietly.

Projects can make the behavior explicit and granular today:

```toml
[manifest.tidy]
# "lexicographic" is the default. "preserve" disables script sorting.
scripts = "lexicographic"
# true is the default. Manual `moon manifest tidy` remains available.
on_script_mutation = true
```

This is intentionally a narrow initial policy. Dependencies, registries,
orbits, and build environment entries are not silently reordered by this
source-aware editor until each domain has equally precise ownership rules.

Scripts are not lockfile facts. `moonstone.lock` records runtimes, dependency
identities, artifacts, target profiles, and realization contracts. Editing a
script changes repository source, not the resolved environment, so there is no
script hash, locked script execution mode, or lock-script query API.
