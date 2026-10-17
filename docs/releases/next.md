# Next release — unreleased

This change completes the CLI consolidation begun in 0.7.0. These commands
belong to the development branch until the next release is tagged; 0.7.0 only
contains the registry migration documented in its own release notes.

| Previous command | Replacement |
| --- | --- |
| `interpreter install lua@5.4` | `add --global lua@5.4` |
| `interpreter set lua@5.4` | `set lua@5.4` |
| `interpreter set --global lua@5.4` | `set --global lua@5.4` |
| `interpreter remove lua@VERSION` | `remove --global lua@VERSION` |
| `interpreter list` | `store list --interpreters` |
| `interpreter current` / `interpreter path` | `env` / `store path` |
| `remove --global --link NAME` | `remove --global link:NAME` |
| `store query --by-package NAME` | `store list --by-package NAME` |
| `store query NAME` / `store list --search NAME` | `store list --query NAME` |
| `index vacuum` | `store prune --compact` |
| `orbit sync NAME` | `--orbit NAME sync` |
| `orbit exec NAME -- COMMAND` | `--orbit NAME exec -- COMMAND` |
| `orbit run NAME -- SCRIPT` | `--orbit NAME run SCRIPT` |
| `orbit sync` | `sync --all` (now includes the root first) |
| `self install --latest` | `self update` |

Project linked dependencies use ordinary `remove NAME`. Unregistering a global
live link preserves its source. Runtime removal refuses referenced artifacts;
`set` explicitly selects a replacement instead of choosing a fallback.

Store listing keeps detailed provenance in STATUS event data and ends with a
count-bearing RESULT. It no longer returns the old query command's bare JSON
array. Exact selectors can be combined with structured filters. A fuzzy query
uses the same matching rule with or without a usable metadata index.

`sync --all` processes the root then direct children in declaration order,
forwards all sync flags, stops on failure, and does not roll back completed
projects. Its JSON output has one final workspace completion. The runtime-only
`--locked` regression is fixed. `--orbit` selects declared names; use `-C` for
arbitrary paths. Shell completion carries the selected project into tool lookup.

`self update` previews the current installer channel's latest-release command;
`self install --version` selects an exact release. `--apply` remains POSIX-only.
Uninstall removes the executable and shims, preserving data by default. Explicit
`--purge-data` lists and removes managed paths, with safety checks. Windows
schedules executable deletion after exit. Package-manager builds remain owned
by their package manager.

See [command workflows](../CLI_WORKFLOWS.md) for scope and examples. `env`,
`exec`, and `run` retain their distinct roles; no activation command is added.
