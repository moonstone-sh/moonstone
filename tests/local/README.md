# Local Test Configuration

This directory is for **untracked developer-machine inputs**, not committed
fixtures. Examples include an installed application path, a private registry,
or a downloaded archive that cannot be recreated from public test inputs.

Committed test scripts must not source files from this directory. CI and other
contributors need deterministic fixtures generated from the repository instead.

If an experiment becomes an enduring test, promote it by committing:

1. a deterministic fixture generator under `tests/lua-tools/` or `tests/helpers/`;
2. an isolated test script under `tests/e2e/` or `tests/windows/`;
3. documented prerequisites and a clean skip when the host cannot provide them.

`macos.env.example` is only a template for local experimentation. Copy it to
`macos.env` if needed; the real file is ignored by Git.
