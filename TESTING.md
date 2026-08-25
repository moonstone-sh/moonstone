# Testing Moonstone

Moonstone keeps its test tiers explicit. A normal checkout should be able to
run the fast and synthetic suites without relying on one contributor's local
registry, downloaded applications, or persistent Moonstone state.

## Fast verification

```bash
tests/run-fast.sh
```

Runs formatting, Zig unit tests, and public contract verification. The
contracts harness installs `packages/contracts` from its checked-in Bun lockfile.

## Synthetic E2E verification

```bash
tests/run-synthetic.sh
```

Builds Moonstone, generates the disposable registry and sandbox, and runs the
E2E suites with `MOONSTONE_REAL_LUAROCKS=0`. This is the broad local workflow
for behavior that must not depend on the public network.

Run one suite directly when iterating:

```bash
zig build
tests/run_lua_tool.sh generate-sandbox --clean
tests/run_lua_tool.sh registry-builder --output-dir fixtures/sandbox
tests/scripts/run_tests.sh --suite commands
```

`tests/scripts/run_tests.sh --include-real-rocks` deliberately adds the pinned
upstream LuaRocks contracts; it is not part of the synthetic default.

## Real LuaRocks compatibility

```bash
tests/run-real-rocks.sh
```

This tier fetches pinned official LuaRocks release bytes, verifies checksums,
and exercises native materialization and locked replay through disposable local
mirrors. It needs network access and the compiler, CMake, SQLite, OpenSSL, or
other native prerequisites each contract declares. A missing prerequisite emits
a skip rather than silently substituting host state.

## Platform coverage

Compile-time target boundaries are always cheap to check:

```bash
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=aarch64-windows-gnu
zig build -Dtarget=riscv64-linux-gnu
```

Native Windows behavior has a dedicated harness:

```powershell
pwsh -File tests/windows/core.ps1
```

From another host, use:

```bash
tests/run-platform.sh windows
```

It reports a skip rather than pretending cross-compilation is native Windows
execution. Add macOS or Linux platform runners only when they own an actual
platform-specific contract.

For a local Windows smoke test on macOS or Linux, Docker can run the x86_64
Windows executable under Wine:

```bash
scripts/test-windows-wine.sh core
```

The harness uses a native build stage and an emulated `linux/amd64` Wine stage,
so it also works on Apple Silicon. It covers the Windows command-line,
environment projection, extensionless launcher resolution, and DLL loader
boundary; native Windows CI remains the authority for Windows itself.

## Local-only experiments

`tests/local/` contains templates and documentation for personal machine
inputs. Real files such as `tests/local/macos.env` are ignored and are never
loaded by committed tests. Promote useful experiments into deterministic
fixture generators and isolated test contracts instead of committing local
paths, downloads, caches, or credentials.

## CI and release certification

`tests/docker/run-linux-ci.sh all` is the closest Linux CI reproduction. The
release workflow runs the broader certification matrix through
`scripts/release/verify-release.sh --with-upstream --with-contracts`.
