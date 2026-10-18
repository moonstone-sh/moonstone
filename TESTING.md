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

## Sync cancellation

After `zig build`, run the real-signal regression matrix against a stalled
loopback registry:

```sh
python3 tests/scripts/test_sync_cancellation.py
```

It checks Ctrl-C during response headers and bodies in default, fancy, plain,
quiet, JSON and CI modes. POSIX hosts also check SIGTERM; Windows checks both
Ctrl-C and Ctrl-Break in an isolated console. Each abort must return within three
seconds with status 130 and must not publish a partial lockfile. Native unit
tests additionally cover blocked worker groups and build-process descendants.

With the synthetic registry generated, add artifact-download and blocked-build
checks (including child-process cleanup):

```sh
python3 tests/scripts/test_sync_cancellation.py --with-fixtures
```

The fixture download/build scenarios run on POSIX hosts. On Windows, run
`zig build test-cancellation` to check that cancellation kills descendants
holding capture pipes open. Build processes start suspended, join a private
kill-on-close Job Object, then resume; ownership failures abort the spawn.
The blocking `Windows Cancellation and Process Ownership` CI job runs this
check and the real console-signal matrix. Tagged release publication also
requires that Windows job to pass. Cross-compilation alone does not
certify Windows runtime behavior.

For compilation without execution, use
`zig build check-cancellation -Dtarget=x86_64-windows-gnu`.

### Native lifecycle release gates

`.github/workflows/native-lifecycle.yml` is reusable by the release workflow.
Windows core environment/projection checks and the installer contracts on
PowerShell 7 and Windows PowerShell 5.1 are blocking. The deferred-update test
serves a fixture installer over loopback HTTP and checks both successful and
failed execution without changing the developer's installed CLI.

Linux and native Apple Silicon/Intel macOS run the same file-registry runtime,
project/orbit, link/store and disposable self-uninstall scenarios. These gates
supplement Windows cancellation/process-tree certification; Wine remains an
additional compatibility signal. Cross-compiled FreeBSD, RISC-V and Windows ARM
artifacts do not acquire native certification merely by compiling.

Windows progress uses ASCII decorations by default. Set
`MOONSTONE_PROGRESS_GLYPHS=unicode` to opt into Unicode decorations with a suitable
terminal/font. The setting does not transliterate filenames. ANSI repainting
requires a console that accepts virtual-terminal processing; redirected output
and `TERM=dumb` stay line-oriented. Windows console geometry is read from the
visible window on each repaint, with environment/default sizes as fallback.

`moon env --shell powershell` emits literal PowerShell assignments. CMD output
is a **batch-file fragment**: save `moon env --shell cmd` to a `.cmd` file and
call it with delayed expansion disabled. A double quote or line break in a value
is rejected rather than emitted as executable CMD syntax. `moon setup` creates
`.cmd` shims on Windows and POSIX shims elsewhere, without changing profiles.

Windows `moon self update --apply` and `moon self install --version VERSION
--apply` schedule the downloaded installer after the current process exits.
Their terminal JSON status is `scheduled`, with a log path; inspect that log for
completion or failure. They preserve the executable's installation directory
and do not change PATH. A scheduled result is not a completed update.

The native Windows gate also runs `tests/windows/terminal.py` in ConPTY. It
resizes a live fancy-progress console, sends keyboard Ctrl-C during a stalled
registry request, and checks bounded cancellation, ASCII decorations, restored
cursor visibility and absence of a partial lockfile. Redirected-stream checks
remain separate so ConPTY's own terminal protocol cannot mask ANSI leakage.
`tests/platform/packaged_lifecycle.py` uses the release archiver, extracts the
native binary, and runs the shared public-command fixture from that archive.

Tagged releases additionally stage the **actual candidate archives** as private
workflow artifacts. Windows x64, both macOS architectures, and Linux x64
GNU/musl runners verify each archive's SHA-256 and version/build label, extract
it, and execute the shared lifecycle scenario. GitHub release publication,
Homebrew updates and Docker publication wait for these archive checks. Failed
certification leaves the public release untouched.
