import * as v from 'valibot';

export const MANIFEST_EXPORT_CONTRACT = 'moonstone:manifest:v1' as const;
export const MANIFEST_EDIT_CONTRACT = 'moonstone:manifest-edit:v1' as const;
export const MANIFEST_EDIT_RESULT_CONTRACT = 'moonstone:manifest-edit-result:v1' as const;

export const storageRevisionSchema = v.pipe(
  v.string(),
  v.regex(/^b3:[0-9a-f]{64}$/),
);

const nonEmptyString = v.pipe(v.string(), v.minLength(1));
const nullableString = v.nullable(v.string());

export const projectSchema = v.strictObject({
  name: nonEmptyString,
  version: nonEmptyString,
  kind: nonEmptyString,
  description: nullableString,
  readme: nullableString,
});

export const runtimeSchema = v.strictObject({
  name: nonEmptyString,
  version: nonEmptyString,
  abi: nonEmptyString,
});

export const originSchema = v.strictObject({
  kind: nonEmptyString,
  url: nonEmptyString,
  revision: nullableString,
  hash: nullableString,
});

export const dependencySchema = v.strictObject({
  name: nonEmptyString,
  constraint: nonEmptyString,
  registry: nullableString,
  role: nonEmptyString,
  optional: v.boolean(),
});

export const scriptSchema = v.strictObject({
  name: nonEmptyString,
  command: nonEmptyString,
});

export const manifestTidySchema = v.strictObject({
  scripts: v.picklist(['lexicographic', 'preserve']),
  on_script_mutation: v.boolean(),
});

export const registrySchema = v.strictObject({
  name: nonEmptyString,
  resolver: nonEmptyString,
  url: nullableString,
  path: nullableString,
  priority: v.pipe(v.number(), v.integer()),
});

export const orbitSchema = v.strictObject({
  name: nonEmptyString,
  path: nonEmptyString,
});

export const manifestDocumentSchema = v.strictObject({
  manifest_version: v.pipe(v.number(), v.integer(), v.minValue(1)),
  project: projectSchema,
  runtime: runtimeSchema,
  origin: v.nullable(originSchema),
  tidy: manifestTidySchema,
  dependencies: v.array(dependencySchema),
  scripts: v.array(scriptSchema),
  registries: v.array(registrySchema),
  orbits: v.array(orbitSchema),
});

export const manifestExportSchema = v.strictObject({
  contract: v.literal(MANIFEST_EXPORT_CONTRACT),
  storage_revision: storageRevisionSchema,
  manifest: manifestDocumentSchema,
});

export const manifestEditDependencySchema = v.strictObject({
  name: nonEmptyString,
  constraint: nonEmptyString,
  registry: v.optional(nullableString),
  role: v.optional(nonEmptyString),
  optional: v.optional(v.boolean()),
});

export const manifestEditRegistrySchema = v.strictObject({
  name: nonEmptyString,
  resolver: nonEmptyString,
  url: v.optional(nullableString),
  path: v.optional(nullableString),
  priority: v.optional(v.pipe(v.number(), v.integer())),
});

export const manifestOperationSchema = v.union([
  v.strictObject({ kind: v.literal('set_script'), name: nonEmptyString, command: nonEmptyString }),
  v.strictObject({ kind: v.literal('remove_script'), name: nonEmptyString }),
  v.strictObject({ kind: v.literal('set_runtime'), runtime: runtimeSchema }),
  v.strictObject({ kind: v.literal('set_dependency'), dependency: manifestEditDependencySchema }),
  v.strictObject({ kind: v.literal('remove_dependency'), name: nonEmptyString }),
  v.strictObject({ kind: v.literal('set_registry'), registry: manifestEditRegistrySchema }),
  v.strictObject({ kind: v.literal('remove_registry'), name: nonEmptyString }),
]);

export const manifestEditSchema = v.strictObject({
  contract: v.literal(MANIFEST_EDIT_CONTRACT),
  expected_revision: storageRevisionSchema,
  operations: v.array(manifestOperationSchema),
});

export const manifestEditResultSchema = v.strictObject({
  contract: v.literal(MANIFEST_EDIT_RESULT_CONTRACT),
  storage_revision: storageRevisionSchema,
  applied: v.pipe(v.number(), v.integer(), v.minValue(0)),
  storage_mode: v.picklist(['source_preserving', 'canonicalized']),
});

export type ManifestExportV1 = v.InferOutput<typeof manifestExportSchema>;
export type ManifestDocumentV1 = v.InferOutput<typeof manifestDocumentSchema>;
export type ManifestScriptV1 = v.InferOutput<typeof scriptSchema>;
export type ManifestTidyV1 = v.InferOutput<typeof manifestTidySchema>;
export type ManifestEditV1 = v.InferOutput<typeof manifestEditSchema>;
export type ManifestOperationV1 = v.InferOutput<typeof manifestOperationSchema>;
export type ManifestEditResultV1 = v.InferOutput<typeof manifestEditResultSchema>;

export const parseManifestExport = (value: unknown): ManifestExportV1 => v.parse(manifestExportSchema, value);
export const parseManifestEdit = (value: unknown): ManifestEditV1 => v.parse(manifestEditSchema, value);
export const parseManifestEditResult = (value: unknown): ManifestEditResultV1 => v.parse(manifestEditResultSchema, value);
