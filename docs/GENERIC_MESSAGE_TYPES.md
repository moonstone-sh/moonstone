# Generic Message Types Specification

**Version:** 0.2.0-bloated  
**Status:** Draft  
**Date:** 2026-05-18

This document defines the Moonstone CLI message protocol. It is intentionally **verbose and explicit** ("bloated") so that wrapper programs, TUI frontends, CI pipelines, and alternative CLIs can consume Moonstone output with zero ambiguity. Every message says exactly what it is, what it is about, and what happened.

---

## Philosophy

- **No magic dots.** The `kind` field tells you the *type of thing happening*, not a hierarchy.
- **Every artifact is named.** Data is keyed by package/runtime/artifact name so you never lose context.
- **Values are plain strings.** `"99.5%"`, `"error.conn-reset"`, `"ok"` — human-readable and machine-parseable.
- **Streams are terminated explicitly.** No EOF guessing. A terminator is sent.

---

## 1. Message Envelope

Every message — NDJSON line or in-stream packet — is wrapped in an envelope:

```json
{
  "kind": "PROGRESS",
  "timestamp": "2026-05-18T04:22:10.123Z",
  "seq": 42,
  "about": "inspect@3.1.1",
  "value": "67%",
  "data": { /* payload */ },
  "terminator": false,
  "meta": { "command": "sync", "pid": 12345, "version": "0.9.0" }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `kind` | `string` | The **type of event**. See §2 Kinds. |
| `timestamp` | `string` | ISO-8601 with milliseconds. |
| `seq` | `uint` | Monotonic sequence number. |
| `about` | `string` | The **subject** of this message: `"inspect@3.1.1"`, `"lua5.4"`, `"env"`, `"lockfile"`. |
| `value` | `string` | The **current state/value**: `"67%"`, `"error.hash-mismatch"`, `"ok"`, `"writing"`. |
| `data` | `object` | Full payload. For multi-artifact commands, this is keyed by artifact name. |
| `terminator` | `bool` | `true` if this is the last message of the stream. |
| `meta` | `object` | Invocation metadata. |

---

## 2. Kinds

Kinds answer: **"What category of thing is happening right now?"**

| Kind | Meaning | Example `value` | Example `about` |
|------|---------|-----------------|-----------------|
| `START` | Command has begun. | `"begin"` | `"sync"` |
| `PROGRESS` | Percentage or stage advancement. | `"67%"`, `"downloading"` | `"inspect@3.1.1"` |
| `STATUS` | A discrete state change. | `"resolved"`, `"cached"`, `"linked"` | `"inspect@3.1.1"` |
| `ERROR` | Something went wrong. | `"error.conn-reset"`, `"error.hash-mismatch"` | `"inspect@3.1.1"` |
| `WARN` | Non-fatal issue. | `"warn.no-source-hash"` | `"lfs@1.0"` |
| `RESULT` | Final aggregate result. | `"ok"`, `"partial"` | `"sync"` |
| `PROMPT` | Needs user interaction. | `"confirm.overwrite"` | `"moonstone.toml"` |
| `INFO` | Extra context. | `"using-registry"` | `"default"` |
| `DUMP` | Raw data dump. | `"env-exports"`, `"manifest"` | `"env"` |

---

## 3. Values

Values answer: **"What exactly is the current reading?"**

### Progress Values

```
"0%" ... "100%"
"downloading"
"resolving"
"materializing"
"linking"
"verifying"
```

### Status Values

```
"queued"
"started"
"resolved"
"downloaded"
"materialized"
"linked"
"cached"          — skipped because present in store
"live"            — live link established
"artifact"        — artifact link established
"written"
"done"
```

### Error Values

```
"error.not-found"              — package not in registry
"error.conn-reset"             — network interrupted
"error.hash-mismatch"          — artifact hash != lockfile
"error.materializer-failed"    — build command exited non-zero
"error.registry-unreachable"   — cannot contact registry
"error.lockfile-required"      — --locked with no lockfile
"error.already-registered"     — link name collision
"error.missing-argument"       — required arg missing
"error.invalid-mode"           — bad --mode value
"error.sqlite-corrupt"         — index database damaged
"error.script-not-found"       — [scripts] entry missing
"error.dangling-symlink"       — env symlink points to void
"error.permission-denied"      — cannot write to store
```

### Result Values

```
"ok"           — total success
"partial"      — some items failed but command continued
"aborted"      — fatal error, stream cut short
"no-op"        — nothing needed to be done
```

### Warn Values

```
"warn.no-source-hash"            — descriptor missing [source]
"warn.link-mode-fallback"        — artifact mode fell back to live
"warn.offline-ignored"           --offline not fully enforced
"warn.orphaned-artifact"         — store artifact has no lockfile reference
```

---

## 4. The `data` Object

### 4.1 Per-Artifact Map

For commands that touch multiple artifacts, `data` is a **map keyed by artifact name**:

```json
{
  "kind": "STATUS",
  "about": "sync",
  "value": "partial",
  "data": {
    "lua5.4": {
      "version": "5.4.6",
      "state": "done",
      "materializer": "prebuilt",
      "bytes_downloaded": 1048576,
      "bytes_total": 1048576,
      "artifact_hash": "b3:a1b2...",
      "elapsed_ms": 1200
    },
    "inspect@3.1.1": {
      "version": "3.1.1",
      "state": "done",
      "materializer": "prebuilt",
      "bytes_downloaded": 65536,
      "bytes_total": 65536,
      "artifact_hash": "b3:c3d4...",
      "elapsed_ms": 400
    },
    "lfs@1.0": {
      "version": "1.0.0",
      "state": "failed",
      "materializer": "command",
      "error": "error.materializer-failed",
      "error_detail": "make: *** No targets specified.",
      "bytes_downloaded": 0,
      "bytes_total": null,
      "elapsed_ms": 800
    }
  }
}
```

This lets a wrapper hold a single object and render a table of all artifacts.

### 4.2 Per-Artifact Schema

Every entry in the `data` map may contain:

| Field | Type | Description |
|-------|------|-------------|
| `version` | `string` | Resolved version. |
| `state` | `string` | One of the Status Values. |
| `materializer` | `string` | `"prebuilt"`, `"command"`, `"native-cmodule"`. |
| `bytes_downloaded` | `uint \| null` | Bytes pulled so far. |
| `bytes_total` | `uint \| null` | Expected total, or `null`. |
| `bytes_per_second` | `float \| null` | Throughput estimate. |
| `artifact_hash` | `string` | BLAKE3 hash. |
| `elapsed_ms` | `uint` | Time spent on this artifact. |
| `error` | `string` | Error value, if failed. |
| `error_detail` | `string` | Human-readable stderr / context. |
| `registry` | `string` | Source registry name. |
| `target` | `string` | Target triple. |
| `cache_hit` | `bool` | Was this already in the store? |

---

## 5. Stream Terminators

Every stream — NDJSON or binary — must be terminated explicitly. The wrapper must not assume EOF equals success.

### 5.1 NDJSON Terminator

The final line is always:

```json
{ "kind": "RESULT", "about": "<command>", "value": "ok", "terminator": true, "seq": 99, "data": {} }
```

or

```json
{ "kind": "RESULT", "about": "<command>", "value": "aborted", "terminator": true, "seq": 99, "data": {}, "error": { "code": "...", "message": "..." } }
```

### 5.2 Binary / Delimited Terminators

If the transport is not newline-friendly (e.g. a raw socket or pipe), use one of these:

| Token | When to use |
|-------|-------------|
| `\0` (null byte) | After a single message when length-prefixing is unavailable. |
| `null` | JSON literal `null` on its own line as a sentinel. |
| `END` | Plain ASCII `END\n` as the final line. |

Wrappers should accept **any** of these and treat them as end-of-stream. For NDJSON, `terminator: true` is preferred.

### 5.3 Example: Full NDJSON Session

```ndjson
{"kind":"START","about":"sync","value":"begin","seq":1,"terminator":false,"data":{},"meta":{"command":"sync","pid":12345}}
{"kind":"STATUS","about":"lua5.4","value":"queued","seq":2,"terminator":false,"data":{"lua5.4":{"version":"5.4.6","state":"queued"}}}
{"kind":"STATUS","about":"inspect@3.1.1","value":"queued","seq":3,"terminator":false,"data":{"inspect@3.1.1":{"version":"3.1.1","state":"queued"}}}
{"kind":"STATUS","about":"lua5.4","value":"resolving","seq":4,"terminator":false,"data":{"lua5.4":{"version":"5.4.6","state":"resolving"}}}
{"kind":"STATUS","about":"lua5.4","value":"downloading","seq":5,"terminator":false,"data":{"lua5.4":{"version":"5.4.6","state":"downloading","bytes_downloaded":0,"bytes_total":1048576}}}
{"kind":"PROGRESS","about":"lua5.4","value":"34%","seq":6,"terminator":false,"data":{"lua5.4":{"bytes_downloaded":356515,"bytes_total":1048576}}}
{"kind":"PROGRESS","about":"lua5.4","value":"89%","seq":7,"terminator":false,"data":{"lua5.4":{"bytes_downloaded":933232,"bytes_total":1048576}}}
{"kind":"STATUS","about":"lua5.4","value":"cached","seq":8,"terminator":false,"data":{"lua5.4":{"version":"5.4.6","state":"cached","artifact_hash":"b3:a1b2...","cache_hit":true}}}
{"kind":"STATUS","about":"inspect@3.1.1","value":"downloading","seq":9,"terminator":false,"data":{"inspect@3.1.1":{"version":"3.1.1","state":"downloading","bytes_downloaded":0,"bytes_total":65536}}}
{"kind":"STATUS","about":"inspect@3.1.1","value":"linked","seq":10,"terminator":false,"data":{"inspect@3.1.1":{"version":"3.1.1","state":"linked","artifact_hash":"b3:c3d4..."}}}
{"kind":"WARN","about":"lfs@1.0","value":"warn.no-source-hash","seq":11,"terminator":false,"data":{"lfs@1.0":{"version":"1.0.0","warn":"Descriptor missing [source] table; hash verification skipped."}}}
{"kind":"STATUS","about":"lfs@1.0","value":"materializing","seq":12,"terminator":false,"data":{"lfs@1.0":{"version":"1.0.0","state":"materializing","materializer":"command"}}}
{"kind":"ERROR","about":"lfs@1.0","value":"error.materializer-failed","seq":13,"terminator":false,"data":{"lfs@1.0":{"version":"1.0.0","state":"failed","error":"error.materializer-failed","error_detail":"make: *** No targets specified and no makefile found."}}}
{"kind":"RESULT","about":"sync","value":"partial","seq":14,"terminator":true,"data":{"lua5.4":{"state":"done"},"inspect@3.1.1":{"state":"done"},"lfs@1.0":{"state":"failed"}},"meta":{"duration_ms":5200,"artifacts_ok":2,"artifacts_failed":1}}
```

---

## 6. React Ink Wrapper Example

A React Ink frontend consuming the bloated protocol.

### 6.1 `moon-tui.jsx`

```jsx
import React, { useState, useEffect, useMemo } from 'react';
import { render, Box, Text, Spacer } from 'ink';
import Spinner from 'ink-spinner';
import ProgressBar from 'ink-progress-bar';
import { spawn } from 'child_process';

// ── NDJSON + Terminator Parser ──────────────────────────────────

function parseBloatedStream(stdout, onMessage, onTerminator) {
  let buffer = '';
  stdout.on('data', (chunk) => {
    buffer += chunk.toString();
    const lines = buffer.split('\n');
    buffer = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      if (line.trim() === 'END') { onTerminator(); continue; }
      if (line.trim() === 'null') { onTerminator(); continue; }
      try {
        const msg = JSON.parse(line);
        onMessage(msg);
        if (msg.terminator === true) onTerminator();
      } catch {}
    }
  });
}

// ── Components ────────────────────────────────────────────────────

function ArtifactRow({ name, info }) {
  const pct = info.bytes_total
    ? Math.round(((info.bytes_downloaded ?? 0) / info.bytes_total) * 100)
    : null;

  const color =
    info.state === 'failed' ? 'red' :
    info.state === 'done' || info.state === 'cached' ? 'green' :
    info.state === 'linked' ? 'cyan' :
    'yellow';

  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text bold color={color}>
        {name} {info.version ? `@${info.version}` : ''} — {info.state ?? 'pending'}
      </Text>
      {pct !== null && info.state !== 'done' && info.state !== 'cached' && (
        <ProgressBar left={2} percent={pct / 100} columns={40} character="█" />
      )}
      {info.error && (
        <Text color="red" dimColor>
          {'  '}↳ {info.error}: {info.error_detail?.slice(0, 60)}
        </Text>
      )}
      {info.warn && (
        <Text color="yellow" dimColor>
          {'  '}↳ {info.warn}
        </Text>
      )}
    </Box>
  );
}

function InstallView() {
  const [messages, setMessages] = useState([]);
  const [terminated, setTerminated] = useState(false);
  const [artifacts, setArtifacts] = useState({});

  useEffect(() => {
    const child = spawn('moon', ['--json', 'sync'], {
      stdio: ['inherit', 'pipe', 'pipe'],
    });

    parseBloatedStream(child.stdout, (msg) => {
      setMessages((prev) => [...prev, msg]);

      // Merge per-artifact data
      if (msg.data && typeof msg.data === 'object') {
        setArtifacts((prev) => {
          const next = { ...prev };
          for (const [name, payload] of Object.entries(msg.data)) {
            next[name] = { ...(next[name] ?? {}), ...payload };
          }
          return next;
        });
      }
    }, () => setTerminated(true));

    return () => child.kill();
  }, []);

  const final = messages[messages.length - 1];
  const overall = final?.value ?? 'working';
  const hasErrors = Object.values(artifacts).some((a) => a.state === 'failed');

  return (
    <Box flexDirection="column" padding={1}>
      <Text bold color="cyan">
        Moonstone TUI
      </Text>

      <Box marginTop={1}>
        {terminated ? (
          overall === 'ok' ? (
            <Text color="green">✓ All done</Text>
          ) : overall === 'partial' ? (
            <Text color="yellow">⚠ Completed with issues</Text>
          ) : (
            <Text color="red">✗ Failed</Text>
          )
        ) : (
          <Text color="yellow">
            <Spinner type="dots" /> Working...
          </Text>
        )}
      </Box>

      <Box marginTop={1} flexDirection="column">
        {Object.entries(artifacts).map(([name, info]) => (
          <ArtifactRow key={name} name={name} info={info} />
        ))}
      </Box>

      {hasErrors && (
        <Box marginTop={1}>
          <Text color="red" dimColor>
            One or more artifacts failed. Check the log above.
          </Text>
        </Box>
      )}

      <Box marginTop={1} flexDirection="column">
        <Text dimColor>Last event: {final?.kind} / {final?.about} = {final?.value}</Text>
      </Box>
    </Box>
  );
}

render(<InstallView />);
```

### 6.2 Running It

```bash
node moon-tui.jsx
```

The wrapper:
1. Spawns `moon --json sync`
2. Parses every NDJSON line, updating a per-artifact state table
3. Renders a live table with progress bars, error details, and warnings
4. Detects `terminator: true`, `null`, or `END` to know when to stop spinning

---

## 7. Command Reference

### 7.1 `moon add`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `add` | `begin` | `{ "packages": ["inspect"], "dev": false }` |
| `STATUS` | `inspect` | `resolving` | `{ "inspect": { "state": "resolving" } }` |
| `STATUS` | `inspect` | `resolved` | `{ "inspect": { "version": "3.1.1", "registry": "default", "state": "resolved" } }` |
| `STATUS` | `inspect` | `cached` | `{ "inspect": { "state": "cached", "cache_hit": true, "path": "~/.moonstone/store/..." } }` |
| `STATUS` | `inspect` | `materialized` | `{ "inspect": { "version": "3.1.1", "state": "materialized", "artifact_hash": "b3:..." } }` |
| `STATUS` | `inspect` | `written` | `{ "inspect": { "version": "3.1.1", "manifest_table": "dependencies.libs", "state": "written" } }` |
| `WARN` | `inspect` | `warn.kind-mismatch` | `{ "inspect": { "warn": "Package resolved as lib but placed in bin due to --bin", "resolved_kind": "lib", "override": "bin" } }` |
| `ERROR` | `inspect` | `error.not-found` | `{ "inspect": { "error": "error.not-found" } }` |
| `ERROR` | `inspect` | `error.conn-reset` | `{ "inspect": { "error": "error.conn-reset" } }` |
| `ERROR` | `inspect` | `error.materializer-failed` | `{ "inspect": { "error": "error.materializer-failed", "error_detail": "make: *** No targets." } }` |
| `RESULT` | `add` | `ok` | `{ "added": ["inspect"], "failed": [], "env_regenerated": true }` |
| `RESULT` | `add` | `partial` | `{ "added": ["inspect"], "failed": ["nonexistent"], "env_regenerated": true }` |
| `RESULT` | `add` | `aborted` | `{ "added": [], "failed": ["inspect"], "env_regenerated": false }` |

### 7.2 `moon remove`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `remove` | `begin` | `{}` |
| `WARN` | `foo` | `warn.not-in-manifest` | `{ "foo": { "warn": "Package not found in manifest; nothing removed." } }` |
| `STATUS` | `inspect` | `removed` | `{ "inspect": { "manifest_table": "dependencies.libs", "state": "removed" } }` |
| `RESULT` | `remove` | `ok` | `{ "removed": ["inspect"], "env_regenerated": true }` |

### 7.3 `moon sync`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `sync` | `begin` | `{ "locked": false, "offline": false }` |
| `STATUS` | `inspect@3.1.1` | `resolving` | `{ "inspect@3.1.1": { "state": "resolving" } }` |
| `STATUS` | `inspect@3.1.1` | `downloading` | `{ "inspect@3.1.1": { "state": "downloading", "bytes_total": 65536 } }` |
| `PROGRESS` | `inspect@3.1.1` | `67%` | `{ "inspect@3.1.1": { "bytes_downloaded": 43890, "bytes_total": 65536 } }` |
| `STATUS` | `inspect@3.1.1` | `cached` | `{ "inspect@3.1.1": { "state": "cached", "cache_hit": true } }` |
| `WARN` | `lfs@1.0` | `warn.no-source-hash` | `{ "lfs@1.0": { "warn": "Descriptor missing [source] table." } }` |
| `STATUS` | `lfs@1.0` | `materializing` | `{ "lfs@1.0": { "state": "materializing", "materializer": "command" } }` |
| `ERROR` | `lfs@1.0` | `error.materializer-failed` | `{ "lfs@1.0": { "state": "failed", "error_detail": "make: *** No targets specified." } }` |
| `ERROR` | `inspect@3.1.1` | `error.hash-mismatch` | `{ "inspect@3.1.1": { "expected_hash": "b3:...", "actual_hash": "b3:..." } }` |
| `STATUS` | `stylua` | `linked` | `{ "stylua": { "state": "linked", "symlink": ".moonstone/env/bin/stylua" } }` |
| `RESULT` | `sync` | `ok` / `partial` / `aborted` | `{ "artifacts_ok": 2, "artifacts_failed": 1, "duration_ms": 5200 }` |

### 7.4 `moon update`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `update` | `begin` | `{ "dry_run": false }` |
| `STATUS` | `inspect@3.1.1` | `resolved` | `{ "inspect@3.1.1": { "old_version": "3.1.0", "new_version": "3.1.1" } }` |
| `STATUS` | `lockfile` | `written` | `{ "lockfile": { "path": "moonstone.lock", "packages_updated": 1 } }` |
| `RESULT` | `update` | `ok` | `{ "updated": ["inspect@3.1.1"], "unchanged": ["lpeg@1.0.2"] }` |

### 7.5 `moon upgrade`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `upgrade` | `begin` | `{ "dry_run": false }` |
| `STATUS` | `inspect` | `constraint-bumped` | `{ "inspect": { "old_constraint": "^3.1", "new_constraint": "^3.2" } }` |
| `STATUS` | `manifest` | `written` | `{ "manifest": { "path": "moonstone.toml", "changes": 1 } }` |
| `RESULT` | `upgrade` | `ok` | `{ "upgraded": ["inspect"], "unchanged": ["lpeg"] }` |

### 7.6 `moon link`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `link` | `begin` | `{}` |
| `STATUS` | `my-lib` | `registered` | `{ "my-lib": { "path": "/abs/path" } }` |
| `ERROR` | `my-lib` | `error.already-registered` | `{ "my-lib": { "error": "error.already-registered" } }` |
| `RESULT` | `link` | `ok` | `{ "registered": "my-lib" }` |

`moon link` only registers the current project globally. Consumers add the
registered dependency with `moon add link:my-lib`.

### 7.7 `moon unlink`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `unlink` | `begin` | `{ "packages": ["my-lib"] }` |
| `WARN` | `my-lib` | `warn.not-linked` | `{ "my-lib": { "warn": "Not a dependency in current project." } }` |
| `STATUS` | `my-lib` | `removed` | `{ "my-lib": { "manifest_table": "dependencies.libs", "state": "removed" } }` |
| `RESULT` | `unlink` | `ok` | `{ "removed": ["my-lib"], "env_regenerated": true }` |

### 7.8 `moon init`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `init` | `begin` | `{ "name": "my-project", "kind": "script" }` |
| `STATUS` | `scaffold` | `written` | `{ "scaffold": { "files_created": ["moonstone.toml", "build.zig.zon", ".gitignore"] } }` |
| `RESULT` | `init` | `ok` | `{ "directory": "my-project", "installed": true }` |

### 7.9 `moon use`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `use` | `begin` | `{ "spec": "lua@5.4" }` |
| `STATUS` | `lua5.4` | `resolved` | `{ "lua5.4": { "version": "5.4.6", "artifact_hash": "b3:..." } }` |
| `STATUS` | `manifest` | `written` | `{ "manifest": { "runtime_updated": true } }` |
| `RESULT` | `use` | `ok` | `{ "installed": true }` |

### 7.10 `moon runtime install`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `runtime-install` | `begin` | `{ "spec": "lua@5.4" }` |
| `STATUS` | `lua5.4` | `resolved` | `{ "lua5.4": { "version": "5.4.6", "target": "x86_64-linux-gnu" } }` |
| `PROGRESS` | `lua5.4` | `34%` | `{ "lua5.4": { "bytes_downloaded": 356515, "bytes_total": 1048576 } }` |
| `STATUS` | `lua5.4` | `done` | `{ "lua5.4": { "path": "~/.moonstone/store/b3/..." } }` |
| `RESULT` | `runtime-install` | `ok` | `{ "path": "~/.moonstone/store/b3/..." }` |

### 7.11 `moon store gc`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `store-gc` | `begin` | `{ "dry_run": false }` |
| `STATUS` | `b3:deadbeef...` | `candidate` | `{ "b3:deadbeef...": { "size": 1048576 } }` |
| `STATUS` | `b3:deadbeef...` | `deleted` | `{ "b3:deadbeef...": { "size": 1048576, "state": "deleted" } }` |
| `RESULT` | `store-gc` | `ok` | `{ "deleted": 3, "freed_bytes": 3145728 }` |

### 7.12 `moon doctor`

| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `doctor` | `begin` | `{ "fix": false }` |
| `STATUS` | `store_directory` | `ok` | `{ "store_directory": { "path": "~/.moonstone/store", "writable": true } }` |
| `STATUS` | `store_directory` | `fixed` | `{ "store_directory": { "path": "~/.moonstone/store", "recreated": true } }` |
| `ERROR` | `store_directory` | `fail` | `{ "store_directory": { "path": "~/.moonstone/store", "error": "error.permission-denied" } }` |
| `STATUS` | `sqlite_index` | `ok` | `{ "sqlite_index": { "path": "~/.moonstone/index/index.sqlite" } }` |
| `ERROR` | `sqlite_index` | `fail` | `{ "sqlite_index": { "path": "~/.moonstone/index/index.sqlite", "error": "error.sqlite-corrupt" } }` |
| `STATUS` | `manifest` | `ok` | `{ "manifest": { "path": "moonstone.toml", "valid": true } }` |
| `ERROR` | `manifest` | `fail` | `{ "manifest": { "path": "moonstone.toml", "error": "error.toml-parse" } }` |
| `STATUS` | `lockfile_artifacts` | `ok` | `{ "lockfile_artifacts": { "missing": 0 } }` |
| `WARN` | `lockfile_artifacts` | `warn.no-lockfile` | `{ "lockfile_artifacts": { "warn": "No lockfile found." } }` |
| `ERROR` | `lockfile_artifacts` | `fail` | `{ "lockfile_artifacts": { "missing": 2 } }` |
| `STATUS` | `env_symlinks` | `ok` | `{ "env_symlinks": { "dangling": [] } }` |
| `STATUS` | `env_symlinks` | `fixed` | `{ "env_symlinks": { "path": ".moonstone/env/bin/lua", "action": "removed_dangling" } }` |
| `WARN` | `env_symlinks` | `warn.dangling-symlink` | `{ "env_symlinks": { "path": ".moonstone/env/bin/lua", "target": "..." } }` |
| `WARN` | `env_symlinks` | `warn.no-runtime` | `{ "env_symlinks": { "warn": "No runtime linked. Run 'moon sync'." } }` |
| `STATUS` | `system_tools` | `ok` | `{ "system_tools": { "missing": [] } }` |
| `WARN` | `system_tools` | `warn.missing-tools` | `{ "system_tools": { "missing": ["gcc", "make"] } }` |
| `RESULT` | `doctor` | `ok` | `{ "issues": 0, "warnings": 0, "checks_passed": 6, "checks_failed": 0 }` |
| `RESULT` | `doctor` | `partial` | `{ "issues": 1, "warnings": 1, "checks_passed": 4, "checks_failed": 2 }` |


| Kind | About | Value | Data Shape |
|------|-------|-------|------------|
| `START` | `registry-add` | `begin` | `{ "name": "my-registry", "url": "https://..." }` |
| `STATUS` | `manifest` | `written` | `{ "manifest": { "registry_added": "my-registry", "set_default": false } }` |
| `RESULT` | `registry-add` | `ok` | `{}` |

---

## 8. Versioning

- **Spec version** lives in `meta.version` of every message.
- Current spec: `0.2.0-bloated`.
- Wrappers must ignore unknown `kind` values and unknown `data` fields.
- The `value` field is freeform; parse defensively.

---

## Appendix A: Error Code Registry

| Error Value | Meaning |
|-------------|---------|
| `error.not-found` | Package not in any registry index. |
| `error.conn-reset` | TCP connection reset during download. |
| `error.hash-mismatch` | Artifact BLAKE3 != lockfile BLAKE3. |
| `error.materializer-failed` | Build command returned non-zero. |
| `error.registry-unreachable` | DNS or HTTP failure. |
| `error.lockfile-required` | `--locked` with no lockfile present. |
| `error.already-registered` | Link name collision. |
| `error.missing-argument` | Required positional argument missing. |
| `error.invalid-mode` | `--mode` not in allowed set. |
| `error.sqlite-corrupt` | Index DB header damaged. |
| `error.script-not-found` | `[scripts]` entry missing. |
| `error.dangling-symlink` | `.moonstone/env/` symlink points to void. |
| `error.permission-denied` | Cannot write store or project dir. |
| `error.health-check-failed` | One or more doctor checks failed. |
| `error.no-compatible-candidate` | No version satisfies constraints. |

## Appendix B: Terminator Rules

| Token | Line Format | Semantics |
|-------|-------------|-----------|
| `"terminator": true` | NDJSON field | This message ends the stream. |
| `\0` | Raw null byte | Message boundary / EOF hint in binary transports. |
| `null` | Plain JSON line | Explicit null sentinel between messages. |
| `END` | Plain text line | Hard stream end. Wrapper may stop reading. |

A compliant wrapper should accept **any** of the above. `terminator: true` is the canonical NDJSON form.

## Appendix D: Command Compliance Matrix

| Command | Status | Implementation Notes |
|---------|--------|----------------------|
| `moon add` | ✅ Full | Uses standard envelopes for resolution and materialization. |
| `moon sync` | ✅ Full | Supports concurrent materialization progress events. |
| `moon doctor` | ✅ Full | Uses standard envelopes for each health check result. |
| `moon use` | ✅ Full | Emits START and RESULT envelopes. |
| `moon list` | ✅ Full | Emits START, STATUS (entries), and RESULT summary. |
| `moon init` | ✅ Full | Emits START and RESULT envelopes. |
| `moon run` | ✅ Full | Emits START and STATUS before handing off to sub-process. |
| `moon exec` | ✅ Full | Emits START and STATUS before spawning sub-process. |
| `moon remove` | ✅ Full | Emits START and RESULT envelopes. |
| `moon version` | ✅ Full | Emits standard RESULT envelope. |

## Appendix E: Environment Variables

| Variable | Description |
|----------|-------------|
| `MOONSTONE_JSON` | Force `--json` behavior even if flag not passed. |
| `MOONSTONE_QUIET` | Suppress human output; implies structured output. |
| `MOONSTONE_PROGRESS_FD` | File descriptor for raw progress (unused in bloated protocol; everything is NDJSON). |
