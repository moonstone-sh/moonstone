import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import Ajv from 'ajv';
import type { AnySchema } from 'ajv';
import { parseLockExport } from '../typescript/lock';

function json(relativePath: string): unknown {
  return JSON.parse(readFileSync(new URL(relativePath, import.meta.url), 'utf8'));
}

test('lock export fixture satisfies schema and Valibot', () => {
  const fixture = json('./fixtures/lock/v1/multi-profile.json');
  const validate = new Ajv({ strict: false }).compile(json('../schema/lock-v1.json') as AnySchema);
  assert.equal(validate(fixture), true, JSON.stringify(validate.errors));

  const lock = parseLockExport(fixture);
  assert.equal(lock.contract, 'moonstone:lock:v1');
  assert.equal(lock.profiles.length, 2);
  assert.equal(lock.packages[0]?.reproducible, true);
  assert.throws(() => parseLockExport({ ...lock, lockfile_version: 1 }));
});
