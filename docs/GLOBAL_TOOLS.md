# Global Tools

Global tools are Moonstone packages installed into a shared tools project instead of the current project. They are useful for ecosystem commands such as `moonstone/love-importer` that you want to run from anywhere.

## Install a Tool Globally

```bash
moon add --global --tool moonstone:moonstone/love-importer
```

`--global` switches into Moonstone's global tools environment and `--tool` records the dependency with tool role semantics. Tool binaries get isolated runtime metadata just like project-local tools.

## Run a Global Tool

```bash
moon exec --global love-importer --help
moon exec --global love-importer import ~/Downloads/love-11.5-macos.zip --version 11.5
```

`moon exec --global` runs inside the global tools environment and still applies per-tool runtime scopes from `.moonstone/env/bin-runtime/<bin>/env.toml`.

See [LÖVE + Moonstone](LOVE.md) for a complete `love-importer` workflow.

## Where Global Tools Live

By default, the global tools project lives at:

```text
~/.local/share/moonstone/projects/global-tools
```

The path follows Moonstone data directory rules:

- `MOONSTONE_DATA` wins when set.
- `MOONSTONE_HOME` maps data to `$MOONSTONE_HOME/data`.
- `XDG_DATA_HOME` maps data to `$XDG_DATA_HOME/moonstone`.
- Otherwise Moonstone uses `~/.local/share/moonstone`.

Inside that project, Moonstone creates a normal project environment:

```text
global-tools/
  moonstone.toml
  moonstone.lock
  .moonstone/env/
    bin/
    bin-runtime/
```

Do not edit `.moonstone/env` or the global store manually. Use Moonstone commands.

## Remove a Global Tool

Global tools are stored as tool-role dependencies, so remove them with `--global --tool`:

```bash
moon remove --global --tool moonstone/love-importer
```

Use `--link` for global link registry entries:

```bash
moon remove --global --link my-linked-package
```

`--bin` remains a deprecated alias for project tool dependencies, but new commands should use `--tool`.

## Relationship to Project Tools

Project-local tool:

```bash
moon add --tool moonstone/ballad
moon exec ballad --help
```

Global tool:

```bash
moon add --global --tool moonstone:moonstone/love-importer
moon exec --global love-importer --help
```

Use project-local tools when a project needs a pinned version in its lockfile. Use global tools for developer utilities that should be available from any directory.
