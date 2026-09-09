#!/usr/bin/env bash
set -euo pipefail

# A failed post-write sync must leave the authored project files exactly as
# they were. The artifact store is intentionally allowed to retain reusable
# materializations; moonstone.toml and moonstone.lock are the transaction.

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-add-transaction.XXXXXX)"
cleanup() {
    chmod u+rwx "${WORKDIR}/.moonstone" 2>/dev/null || true
    if [[ "${MOONSTONE_KEEP_TEST_WORKDIR:-0}" != "1" ]]; then
        rm -rf "${WORKDIR}"
    fi
}
trap cleanup EXIT

cd "${WORKDIR}"
moon init . --name add-transaction --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
cp moonstone.toml before.toml
test ! -e moonstone.lock

# sync reaches environment linking only after add has committed its candidate
# manifest and lock. A file at this path makes that final step fail safely.
mkdir -p .moonstone
printf 'not a directory\n' > .moonstone/env
chmod u=rx,go= .moonstone

if moon add inspect@3.1.3 >add.out 2>&1; then
    echo "expected moon add to fail while linking the environment" >&2
    cat add.out >&2
    exit 1
fi

cmp before.toml moonstone.toml
test ! -e moonstone.lock
if grep -q 'Added .*packages' add.out; then
    echo "moon add reported success before sync completed" >&2
    cat add.out >&2
    exit 1
fi

echo "━━━ ✓ moon add rolls back project files after sync failure ━━━"
