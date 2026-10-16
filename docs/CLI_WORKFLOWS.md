# Choosing the right command

Moonstone provides three related execution interfaces:

| Task | Command | Boundary |
| --- | --- | --- |
| Inspect or export the environment | `moon env`, `moon env --shell zsh` | Produces data or shell code; the caller decides how to consume it. |
| Execute one command | `moon exec -- lua build.lua` | Applies the environment to one child process. Arguments after `--` belong to that process. |
| Execute a project task | `moon run build` | Looks up a named manifest script and runs its command body through the host shell. |

`moon env` is the primitive for shell integrations. Exporting shell code does
not change the parent shell by itself. The supported export syntaxes are Bash,
Zsh, and Fish. Current exports assign variables; they do not provide automatic
restoration of an earlier shell environment. A shell integration that promises
restoration or nesting must implement and verify those behaviors.

`exec` remains useful inside or outside a shell integration because it makes the
process boundary explicit. `run` keeps project task names discoverable. A command
body containing shell-specific syntax does not become portable merely because it
is stored in moonstone.toml.

## Local development links

`moon link` registers a project in the global link store. `moon add link:NAME`
declares a project's use of that link. Registration and dependency declaration
are separate concerns; inspect the project manifest and resolved environment
rather than assuming a shell export silently adds dependencies. No manual
changes to the environment directory or content store are needed.

## Inspection scopes

- `moon list`: dependencies of the current project.
- `moon lock package list --json`: package records in the lockfile.
- `moon env`: the selected runtime and project environment.
- `moon store list`: locally stored or registered content.
- `moon registry list`: registries declared by the current project.

Lock commands expose versioned JSON contracts for tooling. They read
moonstone.lock in the current directory; their help describes the required
arguments. They do not materialize an environment.

## Project sync versus registry maintenance

`moon sync` reconciles a project manifest, lockfile, and environment.
`moon registry NAME: sync` rebuilds a local registry's metadata from its package
descriptors. `moon index rebuild` rebuilds the local store's SQLite metadata
index. These operate on different data.

`moon registry NAME: publish` currently serves
local file-registry authoring. They do not establish support for authenticated
publication to a remote registry. Targeted operations resolve named file://
registries; `--file PATH` addresses a local registry directly.

## Disk space

Caches contain refetchable or rebuildable material. The content store contains
shared artifacts referenced by project environments. Prefer inspecting and
pruning unreferenced content over purging the entire store. Read the command's
scope before deletion; removing user configuration, cached metadata, and shared
artifacts are different operations.

Create a file registry with `moon registry init --file PATH`. Remove a published
version with `moon registry NAME: remove OWNER/PACKAGE@VERSION`. Registry
connections still use `registry add/list/remove`; target operations require the
trailing colon. Use `registry NAME: doctor` for health information.

## Runtime installation and selection

```sh
moon add --global lua@5.4
moon add --global luajit@2.1
moon set lua@5.4
moon set --global luajit@2.1
moon store list --interpreters
moon env
moon store path moonstone/lua@5.4.9
moon remove --global lua@5.4.9
```

`add --global` makes an official runtime available without selecting it. Use
`--runtime` for custom runtime packages. Ordinary global tools still enter the
global tools project. Install one runtime at a time; runtime installation rejects
project dependency-role options. `--target`, `--registry`, `--offline`,
`--prefer-local`, `--dry-run`, and `--json` apply to runtime installation.

`set` selects the project runtime and syncs; `--no-sync` only saves the choice.
`set --global` selects the fallback runtime and creates its configuration when
needed. It does not override project manifests. Runtime inspection uses `env`,
`store list --interpreters`, and `store path`; there is no `interpreter` group.

`remove --global` requires an exact installed runtime version. It refuses to
remove the global selection or an artifact referenced by a known project's
lockfile, environment, or runtime constraint. Sync registers project paths in
portable receipts under the shared projects directory. Retained lock profiles
continue to protect their runtimes. Projects created before this change need a
sync to register them; moved projects need a sync at their new path.

Project dependency removal never chooses a replacement runtime. Use `set`
explicitly. Global runtime removal has no force option that bypasses references.
