package contracts

import (
	"encoding/json"
	"time"
)

type MessageKind string

const (
	KindStart    MessageKind = "START"
	KindProgress MessageKind = "PROGRESS"
	KindStatus   MessageKind = "STATUS"
	KindError    MessageKind = "ERROR"
	KindWarn     MessageKind = "WARN"
	KindResult   MessageKind = "RESULT"
	KindPrompt   MessageKind = "PROMPT"
	KindInfo     MessageKind = "INFO"
	KindDump     MessageKind = "DUMP"
)

// EnvelopeMetadata contains metadata about the CLI invocation.
type EnvelopeMetadata struct {
	Command string `json:"command"`
	PID     int    `json:"pid"`
	Version string `json:"version"`
}

// EnvelopeError represents detailed error properties for result aborts.
type EnvelopeError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// ArtifactData represents properties of individual artifacts in Status/Progress/Error updates.
type ArtifactData struct {
	Version         string   `json:"version,omitempty"`
	State           string   `json:"state,omitempty"`
	Materializer    string   `json:"materializer,omitempty"`
	BytesDownloaded *int64   `json:"bytes_downloaded,omitempty"`
	BytesTotal      *int64   `json:"bytes_total,omitempty"`
	BytesPerSecond  *float64 `json:"bytes_per_second,omitempty"`
	ArtifactHash    string   `json:"artifact_hash,omitempty"`
	ElapsedMs       *int64   `json:"elapsed_ms,omitempty"`
	Error           string   `json:"error,omitempty"`
	ErrorDetail     string   `json:"error_detail,omitempty"`
	Registry        string   `json:"registry,omitempty"`
	Target          string   `json:"target,omitempty"`
	CacheHit        *bool    `json:"cache_hit,omitempty"`
	Warn            string   `json:"warn,omitempty"`
	ResolvedKind    string   `json:"resolved_kind,omitempty"`
	Override        string   `json:"override,omitempty"`
	ManifestTable   string   `json:"manifest_table,omitempty"`
	Symlink         string   `json:"symlink,omitempty"`
	OldVersion      string   `json:"old_version,omitempty"`
	NewVersion      string   `json:"new_version,omitempty"`
	OldConstraint   string   `json:"old_constraint,omitempty"`
	NewConstraint   string   `json:"new_constraint,omitempty"`
	Path            string   `json:"path,omitempty"`
	Recreated       *bool    `json:"recreated,omitempty"`
}

// MessageEnvelope represents the standard outer shape of any Moonstone NDJSON event.
type MessageEnvelope struct {
	Kind       MessageKind      `json:"kind"`
	Timestamp  time.Time        `json:"timestamp"`
	Seq        uint64           `json:"seq"`
	About      string           `json:"about"`
	Value      string           `json:"value"`
	Data       json.RawMessage  `json:"data"` // Postponed parsing for dynamic payloads
	Terminator bool             `json:"terminator"`
	Meta       *EnvelopeMetadata `json:"meta,omitempty"`
	Error      *EnvelopeError   `json:"error,omitempty"`
}

// ── Command-Specific Payload Structs ────────────────────────────────

// AddStartData for 'moon add' START event
type AddStartData struct {
	Packages []string `json:"packages"`
	Dev      bool     `json:"dev"`
}

// AddResultData for 'moon add' RESULT event
type AddResultData struct {
	Added          []string `json:"added"`
	Failed         []string `json:"failed"`
	EnvRegenerated bool     `json:"env_regenerated"`
}

// RemoveResultData for 'moon remove' RESULT event
type RemoveResultData struct {
	Removed        []string `json:"removed"`
	EnvRegenerated bool     `json:"env_regenerated"`
}

// SyncStartData for 'moon sync' START event
type SyncStartData struct {
	Locked  bool `json:"locked"`
	Offline bool `json:"offline"`
}

// SyncResultData for 'moon sync' RESULT event
type SyncResultData struct {
	ArtifactsOk     int `json:"artifacts_ok"`
	ArtifactsFailed int `json:"artifacts_failed"`
	DurationMs      int `json:"duration_ms"`
}

// UpdateStartData for 'moon update' START event
type UpdateStartData struct {
	DryRun bool `json:"dry_run"`
}

// UpdateResultData for 'moon update' RESULT event
type UpdateResultData struct {
	Updated   []string `json:"updated"`
	Unchanged []string `json:"unchanged"`
}

// UpgradeStartData for 'moon upgrade' START event
type UpgradeStartData struct {
	DryRun bool `json:"dry_run"`
}

// UpgradeResultData for 'moon upgrade' RESULT event
type UpgradeResultData struct {
	Upgraded  []string `json:"upgraded"`
	Unchanged []string `json:"unchanged"`
}

// LinkResultData for 'moon link' RESULT event
type LinkResultData struct {
	Registered string `json:"registered"`
}

// UnlinkStartData for 'moon unlink' START event
type UnlinkStartData struct {
	Packages []string `json:"packages"`
}

// UnlinkResultData for 'moon unlink' RESULT event
type UnlinkResultData struct {
	Removed        []string `json:"removed"`
	EnvRegenerated bool     `json:"env_regenerated"`
}

// InitStartData for 'moon init' START event
type InitStartData struct {
	Name string `json:"name"`
	Kind string `json:"kind"`
}

// InitResultData for 'moon init' RESULT event
type InitResultData struct {
	Directory  string `json:"directory"`
	Installed  bool   `json:"installed"`
}

// InterpreterSetStartData for 'moon interpreter set' START event
type InterpreterSetStartData struct {
	Spec string `json:"spec"`
}

// InterpreterSetResultData for 'moon interpreter set' RESULT event
type InterpreterSetResultData struct {
	Installed bool `json:"installed"`
}

// InterpreterInstallStartData for 'moon interpreter install' START event
type InterpreterInstallStartData struct {
	Spec string `json:"spec"`
}

// InterpreterInstallResultData for 'moon interpreter install' RESULT event
type InterpreterInstallResultData struct {
	Path string `json:"path"`
}

// StoreGcStartData for 'moon store gc' START event
type StoreGcStartData struct {
	DryRun bool `json:"dry_run"`
}

// StoreGcResultData for 'moon store gc' RESULT event
type StoreGcResultData struct {
	Deleted    int   `json:"deleted"`
	FreedBytes int64 `json:"freed_bytes"`
}

// DoctorStartData for 'moon doctor' START event
type DoctorStartData struct {
	Fix bool `json:"fix"`
}

// DoctorResultData for 'moon doctor' RESULT event
type DoctorResultData struct {
	Issues       int `json:"issues"`
	Warnings     int `json:"warnings"`
	ChecksPassed int `json:"checks_passed"`
	ChecksFailed int `json:"checks_failed"`
}

// ── Helpers ─────────────────────────────────────────────────────────

// AsArtifactMap decodes the raw message data into a map of ArtifactData.
// This is typically called for PROGRESS, STATUS, WARN, and ERROR kinds.
func (m *MessageEnvelope) AsArtifactMap() (map[string]ArtifactData, error) {
	var result map[string]ArtifactData
	err := json.Unmarshal(m.Data, &result)
	return result, err
}
