# Moonstone CLI & NDJSON Contracts

This directory contains the official typing definitions and schemas for the Moonstone CLI's bloated NDJSON protocol (as specified in the root [CLI_NDJSON_PROTOCOL.md](../../docs/CLI_NDJSON_PROTOCOL.md)).

These definitions allow frontend developers, TUI wrapper authors, and CI pipelines to consume Moonstone's JSON output with complete safety and IDE autocomplete.

---

## 🗂️ Available Contracts

*   **[JSON Schema](./schema/ndjson.json)**: Language-agnostic specification schema for validating NDJSON lines.
*   **[TypeScript Types](./typescript/ndjson.ts)**: Discriminated union types built for TS environments.
*   **[Go Structs](./go/ndjson.go)**: Structs and decoders for Go integrations.
*   **[LuaCATS definitions](./lua/ndjson.lua)**: Standard type annotations for static analysis in Lua environments (LSPs).

---

## 💻 Integration Examples

### TypeScript / Node.js

TypeScript typings use discriminated unions to correctly type the `data` payload depending on the `kind` and `about` values of the envelope:

```typescript
import { spawn } from 'child_process';
import { MoonstoneEnvelope } from './typescript/ndjson';

const child = spawn('moon', ['--json', 'sync']);

child.stdout.on('data', (chunk) => {
  const lines = chunk.toString().split('\n');
  for (const line of lines) {
    if (!line.trim()) continue;
    
    try {
      const envelope = JSON.parse(line) as MoonstoneEnvelope;
      
      // Discriminated unions automatically typecheck the data block!
      if (envelope.kind === 'RESULT' && envelope.about === 'sync') {
        console.log(`Sync complete! OK: ${envelope.data.artifacts_ok}, Failed: ${envelope.data.artifacts_failed}`);
      } else if (envelope.kind === 'STATUS') {
        // Artifact progress mappings
        for (const [pkg, info] of Object.entries(envelope.data)) {
          console.log(`Package: ${pkg}, State: ${info.state}`);
        }
      }
    } catch (e) {
      // Handle parsing / non-json errors
    }
  }
});
```

### Go

Since Go does not natively support discriminated unions, the Go envelope uses `json.RawMessage` for the `Data` field, allowing you to selectively parse the payload using helper decoders:

```go
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"

	"github.com/moonstone-sh/moonstone/packages/contracts/go"
)

func main() {
	cmd := exec.Command("moon", "--json", "sync")
	stdout, _ := cmd.StdoutPipe()
	cmd.Start()

	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		line := scanner.Text()

		var envelope contracts.MessageEnvelope
		if err := json.Unmarshal([]byte(line), &envelope); err != nil {
			continue
		}

		switch envelope.Kind {
		case contracts.KindResult:
			if envelope.About == "sync" {
				var result contracts.SyncResultData
				json.Unmarshal(envelope.Data, &result)
				fmt.Printf("Sync completed. Ok: %d, Failed: %d\n", result.ArtifactsOk, result.ArtifactsFailed)
			}
		case contracts.KindStatus:
			// Extract structured artifact status updates
			artifacts, err := envelope.AsArtifactMap()
			if err == nil {
				for pkg, info := range artifacts {
					fmt.Printf("Artifact %s state: %s\n", pkg, info.State)
				}
			}
		}
	}
}
```

### Lua

Lua developers can cast decoded tables using the annotated classes to get full autocomplete in their editors (e.g. Neovim with `lua-language-server` / LuaCATS):

```lua
-- Assumes a JSON parser like dkjson or cjson is available
local json = require("dkjson")

local line = '{"kind":"RESULT","about":"sync","value":"ok","terminator":true,"data":{"artifacts_ok":3,"artifacts_failed":0,"duration_ms":1200}}'

---@type MessageEnvelope
local envelope = json.decode(line)

if envelope.kind == "RESULT" and envelope.about == "sync" then
    ---@type SyncResultData
    local result = envelope.data
    print(string.format("Materialized %d packages in %dms", result.artifacts_ok, result.duration_ms))
end
```
