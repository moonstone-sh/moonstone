# Teal × Moonstone × Ballad Example

A modern, typed Teal CLI application using [`argparse`](https://github.com/luarocks/argparse) for command-line parsing, built and packaged deterministically into a standalone executable layout using **Ballad**.

## Project Structure

```text
examples/teal-ballad/
├── moonstone.toml   # Project manifest (Teal, argparse, & Ballad dependencies)
├── tlconfig.lua     # Teal compiler configuration
├── partiture.lua    # Ballad build & export pipeline specification
├── src/
│   ├── cli.tl       # CLI interface definition using argparse
│   └── main.tl      # Main entry point
└── README.md
```

## Quick Start

### 1. Install & Sync Dependencies

Resolve `tl`, `argparse`, and `moonstone/ballad` into your hermetic `.moonstone/env/`:

```bash
moon sync
```

### 2. Type Check Teal Code

Run static type checking across your `.tl` sources:

```bash
moon run check
```

### 3. Run Development Code

Execute the entry point directly with arguments:

```bash
moon run run -- --name Moonstone --greeting Welcome --count 3 --verbose
```

### 4. Package Standalone Release Artifacts via Ballad

Export a self-contained executable application layout into `./dist/`:

```bash
moon run export
```

Or run Ballad directly via `moon exec`:

```bash
moon exec ballad play partiture.lua
```

### 5. Run the Exported Executable

```bash
./dist/bin/teal-example --name "Antigravity User" --count 2
```
