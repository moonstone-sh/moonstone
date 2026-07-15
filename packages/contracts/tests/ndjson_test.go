package tests

import (
	"encoding/json"
	"testing"

	"github.com/moonstone-sh/moonstone/packages/contracts/go"
)

func TestParseEnvelope(t *testing.T) {
	rawJSON := `{"kind":"RESULT","about":"sync","value":"ok","terminator":true,"seq":42,"data":{"artifacts_ok":3,"artifacts_failed":0,"duration_ms":1200}}`

	var env contracts.MessageEnvelope
	if err := json.Unmarshal([]byte(rawJSON), &env); err != nil {
		t.Fatalf("failed to unmarshal envelope: %v", err)
	}

	if env.Kind != contracts.KindResult {
		t.Errorf("expected Kind RESULT, got %s", env.Kind)
	}
	if env.About != "sync" {
		t.Errorf("expected About sync, got %s", env.About)
	}
	if env.Seq != 42 {
		t.Errorf("expected Seq 42, got %d", env.Seq)
	}
	if !env.Terminator {
		t.Error("expected Terminator true")
	}

	var syncData contracts.SyncResultData
	if err := json.Unmarshal(env.Data, &syncData); err != nil {
		t.Fatalf("failed to unmarshal inner sync data: %v", err)
	}

	if syncData.ArtifactsOk != 3 {
		t.Errorf("expected ArtifactsOk 3, got %d", syncData.ArtifactsOk)
	}
	if syncData.DurationMs != 1200 {
		t.Errorf("expected DurationMs 1200, got %d", syncData.DurationMs)
	}
}

func TestParseArtifactMap(t *testing.T) {
	rawJSON := `{"kind":"STATUS","about":"sync","value":"partial","terminator":false,"seq":2,"data":{"inspect@3.1.1":{"version":"3.1.1","state":"done","bytes_downloaded":65536,"bytes_total":65536}}}`

	var env contracts.MessageEnvelope
	if err := json.Unmarshal([]byte(rawJSON), &env); err != nil {
		t.Fatalf("failed to unmarshal envelope: %v", err)
	}

	artMap, err := env.AsArtifactMap()
	if err != nil {
		t.Fatalf("failed to unmarshal as artifact map: %v", err)
	}

	inspect, exists := artMap["inspect@3.1.1"]
	if !exists {
		t.Fatal("expected key inspect@3.1.1 not found")
	}

	if inspect.Version != "3.1.1" {
		t.Errorf("expected version 3.1.1, got %s", inspect.Version)
	}
	if inspect.State != "done" {
		t.Errorf("expected state done, got %s", inspect.State)
	}
	if inspect.BytesDownloaded == nil || *inspect.BytesDownloaded != 65536 {
		t.Errorf("expected bytes_downloaded 65536")
	}
}
