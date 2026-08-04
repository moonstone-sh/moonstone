import * as v from 'valibot';

export const LOCK_EXPORT_CONTRACT = 'moonstone:lock:v1' as const;

const nonEmptyString = v.pipe(v.string(), v.minLength(1));
export const storageRevisionSchema = v.pipe(
  v.string(),
  v.regex(/^b3:[0-9a-f]{64}$/),
);

export const lockedPackageSchema = v.strictObject({
  name: nonEmptyString,
  version: nonEmptyString,
  kind: nonEmptyString,
  resolver: nonEmptyString,
  registry: v.string(),
  artifact_hash: v.string(),
  source_hash: v.string(),
  recipe_hash: v.string(),
  runtime: v.string(),
  lua_abi: v.string(),
  target: v.string(),
  replay_mode: nonEmptyString,
  reproducible: v.boolean(),
});

export const lockProfileSchema = v.strictObject({
  id: nonEmptyString,
  target: nonEmptyString,
  runtime: nonEmptyString,
  lua_abi: v.nullable(v.string()),
  package_count: v.pipe(v.number(), v.integer(), v.minValue(0)),
  edge_count: v.pipe(v.number(), v.integer(), v.minValue(0)),
});

export const lockExportSchema = v.strictObject({
  contract: v.literal(LOCK_EXPORT_CONTRACT),
  storage_revision: storageRevisionSchema,
  lockfile_version: v.literal(2),
  packages: v.array(lockedPackageSchema),
  profiles: v.array(lockProfileSchema),
});

export type LockExportV1 = v.InferOutput<typeof lockExportSchema>;
export type LockedPackageV1 = v.InferOutput<typeof lockedPackageSchema>;
export type LockProfileV1 = v.InferOutput<typeof lockProfileSchema>;

export const parseLockExport = (value: unknown): LockExportV1 => v.parse(lockExportSchema, value);
