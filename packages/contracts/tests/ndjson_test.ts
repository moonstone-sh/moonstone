import { MoonstoneEnvelope, SyncResultData, ArtifactData } from '../typescript/ndjson';

function runTests() {
  const syncResultRaw = `{"kind":"RESULT","about":"sync","value":"ok","terminator":true,"seq":42,"data":{"artifacts_ok":3,"artifacts_failed":0,"duration_ms":1200}}`;
  const statusRaw = `{"kind":"STATUS","about":"sync","value":"partial","terminator":false,"seq":2,"data":{"inspect@3.1.1":{"version":"3.1.1","state":"done","bytes_downloaded":65536,"bytes_total":65536}}}`;

  // 1. Verify Sync Result Envelope parsing & type assertions
  const env1 = JSON.parse(syncResultRaw) as MoonstoneEnvelope;
  if (env1.kind !== 'RESULT' || env1.about !== 'sync') {
    throw new Error(`TS test: expected kind RESULT and about sync, got ${env1.kind} / ${env1.about}`);
  }

  // Type system should automatically narrow down envelope.data to SyncResultData
  const syncData = env1.data as unknown as SyncResultData;
  if (syncData.artifacts_ok !== 3) {
    throw new Error(`TS test: expected artifacts_ok 3, got ${syncData.artifacts_ok}`);
  }
  if (syncData.duration_ms !== 1200) {
    throw new Error(`TS test: expected duration_ms 1200, got ${syncData.duration_ms}`);
  }

  // 2. Verify Status Envelope parsing & type assertions
  const env2 = JSON.parse(statusRaw) as MoonstoneEnvelope;
  if (env2.kind !== 'STATUS') {
    throw new Error(`TS test: expected kind STATUS, got ${env2.kind}`);
  }

  const artMap = env2.data as Record<string, ArtifactData>;
  const inspect = artMap['inspect@3.1.1'];
  if (!inspect) {
    throw new Error(`TS test: expected inspect@3.1.1 to exist`);
  }
  if (inspect.version !== '3.1.1') {
    throw new Error(`TS test: expected version 3.1.1, got ${inspect.version}`);
  }
  if (inspect.state !== 'done') {
    throw new Error(`TS test: expected state done, got ${inspect.state}`);
  }
  if (inspect.bytes_downloaded !== 65536) {
    throw new Error(`TS test: expected bytes_downloaded 65536, got ${inspect.bytes_downloaded}`);
  }

  console.log('TypeScript contracts test passed successfully.');
}

runTests();
