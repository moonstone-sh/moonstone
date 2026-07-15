export type MessageKind =
  | 'START'
  | 'PROGRESS'
  | 'STATUS'
  | 'ERROR'
  | 'WARN'
  | 'RESULT'
  | 'PROMPT'
  | 'INFO'
  | 'DUMP';

export interface EnvelopeMetadata {
  command: string;
  pid: number;
  version: string;
}

export interface EnvelopeError {
  code: string;
  message: string;
}

export interface ArtifactData {
  version?: string;
  state?: string;
  materializer?: string;
  bytes_downloaded?: number | null;
  bytes_total?: number | null;
  bytes_per_second?: number | null;
  artifact_hash?: string;
  elapsed_ms?: number;
  error?: string;
  error_detail?: string;
  registry?: string;
  target?: string;
  cache_hit?: boolean;
  warn?: string;
  resolved_kind?: string;
  override?: string;
  manifest_table?: string;
  symlink?: string;
  old_version?: string;
  new_version?: string;
  old_constraint?: string;
  new_constraint?: string;
  path?: string;
  recreated?: boolean;
}

// ── Command Payload Types ─────────────────────────────────────────

export interface AddStartData {
  packages: string[];
  dev: boolean;
}

export interface AddResultData {
  added: string[];
  failed: string[];
  env_regenerated: boolean;
}

export interface RemoveResultData {
  removed: string[];
  env_regenerated: boolean;
}

export interface SyncStartData {
  locked: boolean;
  offline: boolean;
}

export interface SyncResultData {
  artifacts_ok: number;
  artifacts_failed: number;
  duration_ms: number;
}

export interface UpdateStartData {
  dry_run: boolean;
}

export interface UpdateResultData {
  updated: string[];
  unchanged: string[];
}

export interface UpgradeStartData {
  dry_run: boolean;
}

export interface UpgradeResultData {
  upgraded: string[];
  unchanged: string[];
}

export interface LinkResultData {
  registered: string;
}

export interface UnlinkStartData {
  packages: string[];
}

export interface UnlinkResultData {
  removed: string[];
  env_regenerated: boolean;
}

export interface InitStartData {
  name: string;
  kind: string;
}

export interface InitResultData {
  directory: string;
  installed: boolean;
}

export interface InterpreterSetStartData {
  spec: string;
}

export interface InterpreterSetResultData {
  installed: boolean;
}

export interface InterpreterInstallStartData {
  spec: string;
}

export interface InterpreterInstallResultData {
  path: string;
}

export interface StoreGcStartData {
  dry_run: boolean;
}

export interface StoreGcResultData {
  deleted: number;
  freed_bytes: number;
}

export interface DoctorStartData {
  fix: boolean;
}

export interface DoctorResultData {
  issues: number;
  warnings: number;
  checks_passed: number;
  checks_failed: number;
}

// ── Discriminated Envelopes ───────────────────────────────────────

export interface Envelope<K extends MessageKind, A extends string, V extends string, D> {
  kind: K;
  timestamp: string;
  seq: number;
  about: A;
  value: V;
  data: D;
  terminator: boolean;
  meta?: EnvelopeMetadata;
  error?: EnvelopeError;
}

// Union type for all possible envelopes
export type MoonstoneEnvelope =
  // add
  | Envelope<'START', 'add', 'begin', AddStartData>
  | Envelope<'STATUS' | 'PROGRESS' | 'WARN' | 'ERROR', string, string, Record<string, ArtifactData>>
  | Envelope<'RESULT', 'add', 'ok' | 'partial' | 'aborted', AddResultData>
  // remove
  | Envelope<'START', 'remove', 'begin', Record<string, never>>
  | Envelope<'RESULT', 'remove', 'ok', RemoveResultData>
  // sync
  | Envelope<'START', 'sync', 'begin', SyncStartData>
  | Envelope<'RESULT', 'sync', 'ok' | 'partial' | 'aborted', SyncResultData>
  // update
  | Envelope<'START', 'update', 'begin', UpdateStartData>
  | Envelope<'RESULT', 'update', 'ok', UpdateResultData>
  // upgrade
  | Envelope<'START', 'upgrade', 'begin', UpgradeStartData>
  | Envelope<'RESULT', 'upgrade', 'ok', UpgradeResultData>
  // link
  | Envelope<'START', 'link', 'begin', Record<string, never>>
  | Envelope<'RESULT', 'link', 'ok', LinkResultData>
  // unlink
  | Envelope<'START', 'unlink', 'begin', UnlinkStartData>
  | Envelope<'RESULT', 'unlink', 'ok', UnlinkResultData>
  // init
  | Envelope<'START', 'init', 'begin', InitStartData>
  | Envelope<'RESULT', 'init', 'ok', InitResultData>
  // interpreter set
  | Envelope<'START', 'use', 'begin', InterpreterSetStartData>
  | Envelope<'RESULT', 'use', 'ok', InterpreterSetResultData>
  // interpreter install
  | Envelope<'START', 'runtime-install', 'begin', InterpreterInstallStartData>
  | Envelope<'RESULT', 'runtime-install', 'ok', InterpreterInstallResultData>
  // store gc
  | Envelope<'START', 'store-gc', 'begin', StoreGcStartData>
  | Envelope<'RESULT', 'store-gc', 'ok', StoreGcResultData>
  // doctor
  | Envelope<'START', 'doctor', 'begin', DoctorStartData>
  | Envelope<'RESULT', 'doctor', 'ok' | 'partial', DoctorResultData>;
