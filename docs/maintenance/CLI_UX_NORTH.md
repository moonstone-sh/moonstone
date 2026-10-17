# Moonstone CLI UX north

Status: initial audit recorded 2026-10-15; command consolidation implemented on
`feat/runtime-command-consolidation`. The audit inventory below is historical.
Runtime add/remove/set, explicit link removal, unified store listing, prune
compaction, global orbit selection, root-first workspace sync, and self lifecycle
are covered by the current change. See `../CLI_WORKFLOWS.md` for the maintained
command contract. Broader UX acceptance goals remain measurements to perform,
not claims inferred from implementation tests.

## North

**From a fresh checkout to a working Lua environment, with no guessing about
what runs, what changes, or how to recover.**

Moonstone should feel dependable before it feels clever. Deterministic
resolution, runtime isolation, and portable artifacts support that experience;
they should not require a newcomer to understand the store or lockfile schema.

Primary audience: Lua developers trying Moonstone for the first time. Advanced
users and automation keep the same underlying commands, with detailed inspection
and stable machine interfaces available when needed.

## Goals and evidence

| Goal | Acceptance evidence |
| --- | --- |
| Reach a first success | An unfamiliar Lua developer initializes/adopts a project, selects a runtime, adds a package, and runs code without editing environment variables. Target: five minutes after installation; measure it before claiming it. |
| Make scope visible | Help and mutation summaries distinguish current project, orbit, user/global configuration, cache, store, and local registry. Show the resolved path when ambiguity matters. |
| Make execution predictable | `exec` forwards argument boundaries, exit status, terminal input, and cancellation correctly. Test spaces, Unicode, empty arguments, shell metacharacters, nested `--`, nonzero exits, and child processes on each supported OS. |
| Support comfortable interactive work | Users can enter and leave an environment without losing prior PATH/Lua variables; nested sessions and project switching have defined behavior. |
| Tell the truth | Every advertised option is implemented; shell support and platform exceptions are explicit. No help text advertises planned behavior as shipped. |
| Recover without detective work | Failures explain what failed, the relevant scope/path, and a concrete next action. Cancellation cleans up owned work and releases locks; it does not hang indefinitely. |
| Serve automation reliably | Document and test machine output per command, stdout/stderr ownership, exit codes, and child-output forwarding. Do not rename a stream JSON when it is NDJSON. |
| Keep multi-project work understandable | A two-project workspace proves what orbits add beyond `moon -C PATH`; independent runtimes, traversal, execution, and partial failure are explained. |

## Command hierarchy

Keep existing commands working. First improve help grouping and examples;
renaming requires a separate migration decision.

| Reader task | Existing surface | Direction |
| --- | --- | --- |
| Start and run | init, add, remove, sync, run, exec, list | Lead root help with the first-success path. Explain changes to manifest/lock/environment and whether synchronization follows. |
| Select and inspect an environment | interpreter, env | Distinguish saved interpreter selection from an execution-only override. Explain project versus global scope. |
| Work interactively | setup, completions, env --shell | Use `moon env` as the shell-integration primitive. Retain `exec` for explicit process execution and `run` for named tasks; no new activation command is proposed. |
| Work across projects | orbit | Define an orbit as a separately resolvable child project. Compare it with `-C`; do not present it as pooled dependencies or shared activation. |
| Diagnose and maintain | doctor, version, config, cache, store, self | Separate inspection from repair/deletion. Make destructive scope and recovery limits visible. |
| Author and automate | manifest, lock, artifact, provision | Complete reference help without placing internal schema vocabulary in the first-success path. |
| Operate a registry | registry, index | Distinguish registry configuration from local registry maintenance. State supported transport for targeted operations. |

## Findings confirmed in this audit

- Root help lists 25 command families in one flat list, mixing everyday actions
  with index maintenance and semantic lockfile tooling.
- 91 static help nodes were visited: 19 groups and 72 executable commands.
  All returned exit 0. This verifies help dispatch, not command behavior.
- 16 executable commands return a one-line help response, without a complete
  usage/argument/example contract. They are enumerated below.
- `env --help` advertises bash, zsh, fish, cmd, and powershell. `env.zig` only
  emits POSIX or Fish exports; the unsupported-shell branch prints a message
  without an error return. Help and behavior therefore disagree.
- `setup` says it creates shims for “lua, moon exec, etc.”; its implementation
  creates `lua` and `luac` shims. It also includes a future shell-profile-editing
  step in current help. Shims are POSIX scripts and use `chmod`; Windows claims
  need separate validation.
- Several public help strings call machine output “bloated protocol”; doctor
  additionally points at a stale-looking internal document path. Replace this
  with the actual output contract, after checking each command's emitter.
- `run` documents a host-shell command body, whereas `exec` documents verbatim
  argv forwarding after mandatory `--`. Preserve and explain that distinction;
  a shell script is not automatically cross-platform because Moonstone runs it.
- Registry target dispatch (`registry <name>:` or `--file`) is separate from the
  static help tree. It exposes publish, index rebuild, descriptor fetch, package
  deletion, settings inspection, and doctor. Named target resolution currently
  accepts file:// registries only. These operations were source-inspected, not
  executed; local publication is not evidence of remote authenticated publishing.
- `remove` combines dependency removal and global-link removal; `--global`,
  role selectors, and mutation summaries need journey-level checks.

The observed binary reports Moonstone 0.6.0. Source was inspected at local
commit b6190b1 on feat/lua-flavors. The binary was not rebuilt for this audit;
behavior beyond captured help must be verified against a fresh build. No
mutating commands, production state changes, or destructive tests were run.

## Launch backlog

### P0: trustworthy behavior and claims

1. Correct unsupported shell claims and return a failure for unsupported shell
   export requests. Complete the missing leaf help. Remove future features and
   internal protocol nicknames from user-facing help.
2. Audit cancellation across resolution, index fetch, downloads, native builds,
   materialization, script execution, and orbit traversal. Include Windows
   console events and child-process trees. Proposed bound: return control within
   two seconds after cancellation is accepted; document and test any exception.
3. Establish the execution portability matrix. Cover macOS/Linux/Windows;
   POSIX shells, Fish, PowerShell, and CMD where advertised. Verify platform
   launchers rather than assuming PATH export is sufficient.
4. Audit destructive operations in disposable homes/registries: config reset,
   store purge/prune, cache clear, interpreter removal, self uninstall, registry
   purge/delete. Specify exactly what data is removed and what can be recovered.
5. Run first-success and recovery journeys from clean installations. Prevent
   tests from passing through globally installed runtimes/tools accidentally.

### P1: discovery and flow

6. Group root help by user task; give each leaf a consistent usage, scope,
   options, one useful example, and recovery pointer where appropriate.
7. Strengthen the `moon env` export contract. Shell integrations consume its
   output; they do not need a competing activation primitive. Test quoting,
   variable handling, repeated application, and project switching. Current
   exports alone do not restore previous variables; integrations must not claim
   reversibility without providing it.
8. Prove or simplify orbits with a real web/server or game/tool workspace.
   Surface child names and failures; retain useful independent execution.
9. Align completions, terminal diagnostics, and docs with the same command
   metadata so usage does not drift between surfaces.

### P2: refinements after the journeys pass

10. Evaluate shorter aliases and whether `interpreter` should appear as `runtime`
    in beginner explanations. Do not remove existing spelling casually.
11. Improve progress pacing, terminal-width behavior, quiet/plain/non-TTY modes,
    and summaries. Establish tests for meaning rather than exact decorative text.

## What we are not committing to yet

No wholesale command renaming, activation requirement, orbit removal, or new
project model. No claim that named shell scripts are portable. No claim that
remote publishing/login exists merely because local registry commands exist.
Finish the journeys before expanding the surface.

## Review sequence

1. Review this north and the command grouping.
2. Ship help/capability-truth fixes as a small change.
3. Run the execution/cancellation/shell matrix in isolated fixtures.
4. Make the shell/orbit decisions from those results.
5. Update documentation and demonstrate fresh-project, adoption, multi-project,
   LÖVE packaging, and recovery flows before the public launch.

## First implementation pass

The feat/cli-ux-polish branch completes help for the 16 one-line leaves,
corrects shell/setup claims, names NDJSON output accurately, and explains
`env`/`exec`/`run` in the environment help. Unsupported shell requests fail before
environment discovery. Metadata-cache `all` selection now differs from invalid
input. Existing command names and machine-output schemas remain unchanged.

Validation: fresh Zig build, focused CLI contract tests, all 91 help nodes,
unsupported-shell NDJSON/exit status/no-global-state behavior, and explicit
metadata-cache `all` selection in a disposable Moonstone home.

The inventory below records the original audit, not post-change line counts.
Behavioral platform, export quoting, cancellation, and orbit-workflow audits
remain outstanding. No activation/shell command or command renaming was added.

## Static command inventory

Each row was checked with `--help`; groups are included so no discovered static
branch is omitted. Line counts flag reference gaps, not usability scores.

| Command | Kind | Help lines |
| --- | --- | ---: |
| `moon` | group | 33 |
| `moon add` | command | 25 |
| `moon sync` | command | 14 |
| `moon init` | command | 22 |
| `moon setup` | command | 9 |
| `moon link` | command | 9 |
| `moon run` | command | 10 |
| `moon exec` | command | 17 |
| `moon remove` | command | 17 |
| `moon list` | command | 6 |
| `moon doctor` | command | 7 |
| `moon version` | command | 6 |
| `moon env` | command | 11 |
| `moon completions` | command | 10 |
| `moon manifest` | group | 9 |
| `moon lock` | group | 11 |
| `moon self` | group | 7 |
| `moon store` | group | 11 |
| `moon artifact` | group | 6 |
| `moon provision` | group | 6 |
| `moon index` | group | 9 |
| `moon registry` | group | 12 |
| `moon cache` | group | 7 |
| `moon config` | group | 10 |
| `moon interpreter` | group | 11 |
| `moon orbit` | group | 11 |
| `moon manifest export` | command | 7 |
| `moon manifest apply` | command | 9 |
| `moon manifest tidy` | command | 7 |
| `moon manifest script` | group | 9 |
| `moon lock export` | command | 1 |
| `moon lock verify` | command | 1 |
| `moon lock profile` | group | 7 |
| `moon lock package` | group | 7 |
| `moon lock realization` | group | 7 |
| `moon lock graph` | group | 6 |
| `moon self install` | command | 9 |
| `moon self uninstall` | command | 7 |
| `moon store prune` | command | 7 |
| `moon store verify` | command | 8 |
| `moon store path` | command | 11 |
| `moon store list` | command | 13 |
| `moon store query` | command | 13 |
| `moon store purge` | command | 7 |
| `moon artifact create` | command | 13 |
| `moon provision resolve` | command | 14 |
| `moon index rebuild` | command | 6 |
| `moon index check` | command | 6 |
| `moon index stats` | command | 6 |
| `moon index vacuum` | command | 3 |
| `moon registry list` | command | 6 |
| `moon registry add` | command | 20 |
| `moon registry remove` | command | 6 |
| `moon registry create` | command | 8 |
| `moon registry sync` | command | 8 |
| `moon registry push` | command | 15 |
| `moon registry purge` | command | 15 |
| `moon cache clean` | command | 6 |
| `moon cache manifest` | group | 9 |
| `moon config show` | command | 6 |
| `moon config get` | command | 4 |
| `moon config set` | command | 4 |
| `moon config unset` | command | 3 |
| `moon config reset` | command | 6 |
| `moon interpreter set` | command | 13 |
| `moon interpreter install` | command | 11 |
| `moon interpreter remove` | command | 8 |
| `moon interpreter list` | command | 10 |
| `moon interpreter current` | command | 6 |
| `moon interpreter path` | command | 14 |
| `moon orbit add` | command | 10 |
| `moon orbit list` | command | 6 |
| `moon orbit remove` | command | 3 |
| `moon orbit sync` | command | 11 |
| `moon orbit exec` | command | 19 |
| `moon orbit run` | command | 18 |
| `moon manifest script list` | command | 1 |
| `moon manifest script get` | command | 1 |
| `moon manifest script set` | command | 1 |
| `moon manifest script remove` | command | 1 |
| `moon lock profile list` | command | 1 |
| `moon lock profile get` | command | 1 |
| `moon lock package list` | command | 1 |
| `moon lock package get` | command | 1 |
| `moon lock realization list` | command | 1 |
| `moon lock realization get` | command | 1 |
| `moon lock graph export` | command | 1 |
| `moon cache manifest list` | command | 3 |
| `moon cache manifest refresh` | command | 1 |
| `moon cache manifest path` | command | 1 |
| `moon cache manifest clear` | command | 1 |

## Registry consolidation implemented

The static registry authoring commands have been removed. Use `registry init
--file PATH`, then targeted `publish`, `sync`, `fetch`, `remove`, or `doctor`.
Connection management remains `registry add/list/remove`. The inventory above
records the original surface before consolidation. `settings show` is removed;
health checks belong to `doctor`. Target authoring currently supports file
registries, not authenticated remote publishing.

## Runtime consolidation implemented

The public interpreter group is removed. Runtime installation/removal now uses
`add --global` and `remove --global`, selection uses `set`, and inspection uses
`env`, `store list --interpreters`, and `store path`. The original inventory is
historical. This implementation also registers synced projects so reference
checks can protect their artifacts, including retained lock profiles.

## Remaining command consolidation implemented

The same branch now completes the store, link, orbit, and lifecycle decisions.
`store list --query` includes exact selectors and provenance-rich NDJSON;
`store prune --compact` owns compaction. Project links use ordinary dependency
removal, while `remove --global link:NAME` unregisters explicitly and preserves
source files. Only unreferenced, owned artifact materializations are reclaimed.

`--orbit NAME` is a global project selector, composable with `-C`. Orbit commands
only manage declarations. `sync --all` synchronizes root then direct children,
forwards flags, and stops on failure without rollback. Completion uses the same
project selection. The runtime-only fresh-lock regression is covered.

`self update` selects the install channel's latest release; `self install
--version` selects an exact release. Uninstall preserves data by default,
removes executable/shims, and guards explicit managed-data purges. Windows
schedules executable removal after process exit. Package-manager ownership and
the POSIX-only installer apply limit remain explicit.

These changes belong to corrected 0.7.0; see `../releases/0.7.0.md`. The original inventory
is retained as audit history rather than presented as the current command tree.
