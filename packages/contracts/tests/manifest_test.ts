import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import Ajv from 'ajv';
import type { AnySchema } from 'ajv';
import {
  parseManifestEdit,
  parseManifestEditResult,
  parseManifestExport,
} from '../typescript/manifest';

function json(relativePath: string): unknown {
  return JSON.parse(readFileSync(new URL(relativePath, import.meta.url), 'utf8'));
}

function assertSchema(schemaPath: string, value: unknown): void {
  const validate = new Ajv({ strict: false }).compile(json(schemaPath) as AnySchema);
  assert.equal(validate(value), true, JSON.stringify(validate.errors));
}

test('manifest export fixture satisfies schema and Valibot', () => {
  const fixture = json('./fixtures/manifest/v1/full.json');
  assertSchema('../schema/manifest-v1.json', fixture);
  const manifest = parseManifestExport(fixture);
  assert.equal(manifest.contract, 'moonstone:manifest:v1');
  assert.equal(manifest.manifest.scripts[0]?.command, 'zig fmt --check . && zig build "$@"');
  assert.throws(() => parseManifestExport({ ...manifest, unexpected: true }));
});

test('manifest edit fixtures satisfy schemas and Valibot', () => {
  const editFixture = json('./fixtures/manifest-edit/v1/set-script.json');
  assertSchema('../schema/manifest-edit-v1.json', editFixture);
  const edit = parseManifestEdit(editFixture);
  assert.equal(edit.operations.length, 2);
  assert.throws(() => parseManifestEdit({ ...edit, expected_revision: 'not-a-revision' }));

  const resultFixture = json('./fixtures/manifest-edit-result/v1/applied.json');
  assertSchema('../schema/manifest-edit-result-v1.json', resultFixture);
  assert.equal(parseManifestEditResult(resultFixture).applied, 2);
});
