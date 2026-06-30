import re

with open("src/cli/commands/sync.zig", "r") as f:
    content = f.read()

# Remove Phase 1b
content = re.sub(
    r"        // ── Phase 1b: Parallel Blake3 hash verification ──────────────────────.*?        var live_links = std.ArrayList",
    r"        var live_links = std.ArrayList",
    content,
    flags=re.DOTALL
)

# Remove HashVerifyPool
content = re.sub(
    r"// ────────────────────────────────────────────────────────────────────────────\n//  Hash verification pool — parallel Blake3 verification of materialized artifacts\n// ────────────────────────────────────────────────────────────────────────────\n\nconst VerifyJob = struct \{.*?\n\n};",
    r"",
    content,
    flags=re.DOTALL
)

with open("src/cli/commands/sync.zig", "w") as f:
    f.write(content)
