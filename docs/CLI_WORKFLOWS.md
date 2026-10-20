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

## Workspace selection

Keep orbit declarations for stable names and discovery; use ordinary commands
inside them:

```sh
moon orbit add --name server --path apps/server
moon -C . --orbit server sync --locked
moon --orbit server exec -- lua main.lua
moon --orbit server run test
moon sync --all --offline
```

`sync --all` preflights member paths, then synchronizes the root followed by its
direct members in declaration order. Each keeps its own lock and environment.
All sync flags carry through. Failure stops traversal; completed changes remain.
There is no recursive traversal or rollback. Combining `--orbit` and `--all` is
an error. With `--json`, project events share one sequence and a single final
`workspace.complete` RESULT; individual member completion is a STATUS.
`orbit add/list/remove` manage declarations; `-C PATH` addresses any
project without declaring an orbit.

## Local links and store maintenance

```sh
moon link                            # register current source project
moon add link:my-library
moon remove my-library               # remove ordinary project dependency
moon remove --global link:my-library # unregister; preserve source files
moon store list --query valua --kind lib --json
moon store list --by-artifact-hash b3:HASH --json
moon store prune --compact --dry-run
moon store prune --compact
```

Global link removal validates every requested registration before changing any.
Live source directories are never deleted. Only registered artifact-mode links
whose paths are canonical CAS materializations are eligible for reclamation;
other links and registered project locks protect shared artifacts.

`store list` accepts one name query or exact selector (`--by-package`,
`--by-artifact-hash`, `--by-source-hash`) and combines it with kind, resolver,
target, and ABI filters. JSON is NDJSON: START, one STATUS per artifact, then a
RESULT with the count. Artifact data retains hashes, provenance, paths, and
warnings. `--links` lists registrations using the same event envelope.
`store query` is removed. Index compaction belongs to `store prune --compact`;
`--dry-run` never compacts. `index vacuum` is removed.

## CLI installation lifecycle

```sh
moon self update                       # preview latest-release installer
moon self update --apply               # run installer; scheduled on Windows
moon self install --version 0.7.0       # preview exact-release installer
moon self uninstall --dry-run --json
moon self uninstall --yes              # executable and shims only
moon self uninstall --yes --purge-data # also remove listed managed data
```

Self-managed builds retain their configured installer channel. Externally
managed builds direct users to their package manager instead of overwriting its
files. Windows previews a PowerShell installer command. With `--apply`, it
downloads the installer and schedules it after the CLI exits so its executable
can be replaced. The result is `scheduled`, not a completed installation; the
reported log records completion or failure. The current installation directory
and PATH are preserved.
Uninstall removes the running executable on POSIX; Windows schedules removal
after the process exits. Store, caches, configuration, and project tracking
survive by default. `--purge-data` previews and deletes specific managed paths,
not their parent directories, and refuses home/root/current-project ancestors.
Project sources and unrelated files are preserved. Deletion is irreversible;
there is no rollback if a later filesystem operation fails.


## Windows shell integration

`moon env --shell powershell` emits literal environment assignments for the
current project. Consume them in your current PowerShell session when desired:

```powershell
moon env --shell powershell | Out-String | Invoke-Expression
```

`moon env --shell cmd` produces a batch-file fragment, not interactive CMD
syntax. Save it as UTF-8 without a BOM and call it with delayed expansion off
and code page 65001 when paths contain Unicode. Do not save native output using
Windows PowerShell 5.1's default UTF-16 redirection. `moon exec -- <command>`
avoids shell export/encoding concerns by applying the environment to a child.

`moon setup` creates `lua.cmd` and `luac.cmd` on Windows, and executable POSIX
shims elsewhere. Add the reported shim directory to PATH yourself; Moonstone
does not modify your shell profile. Both shims delegate to `moon exec`, so the
current project chooses the runtime.

Windows progress defaults to ASCII. Unicode decorations are opt-in through
`MOONSTONE_PROGRESS_GLYPHS=unicode`; filenames remain Unicode in either mode.
See [native certification](../TESTING.md#native-lifecycle-release-gates) for the
platform checks that block publication and targets without native runners.


## Script arguments

Plain scripts are commands, not shell expressions. Moonstone splits their fixed
arguments using single/double quotes for grouping, then appends arguments from
`moon run` directly. It does not expand variables, globs, pipes, or redirects.

```toml
[scripts]
build = "lua build.lua"
check = 'lua "scripts/check project.lua"'
```

```sh
moon run build -- --watch "two words"
```

`build.lua` receives `--watch` and `two words` on Windows, macOS, and Linux.
Empty arguments, Unicode, and shell metacharacters in forwarded arguments stay
data. Remove trailing `"$@"` or `%*` from plain scripts; Moonstone reports a
migration error rather than forwarding them as literal arguments.

Use an explicit shell table for a pipeline, environment expansion, or a shell
builtin. The shell body owns argument placement:

```toml
[scripts]
build = { shell = 'lua generate.lua && lua build.lua "$@"' }
```

That example is POSIX shell syntax. On Windows, shell mode runs a temporary
batch file with delayed expansion disabled; use `%*` to place its arguments.
Explicit shell scripts remain platform-specific. Prefer a Lua script or a
plain command when the same declaration must run on every host.

Quotes in a plain command only group text. Backslashes remain path data except
when escaping a quote or unquoted whitespace; single-quoted Windows paths keep
backslashes literally. Forwarded arguments are never parsed again by Moonstone.
