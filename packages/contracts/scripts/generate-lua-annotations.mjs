import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const targets = [
  {
    output: 'lua/manifest.lua',
    schemas: [
      'schema/manifest-v1.json',
      'schema/manifest-edit-v1.json',
      'schema/manifest-edit-result-v1.json',
    ],
  },
  {
    output: 'lua/lock.lua',
    schemas: ['schema/lock-v1.json'],
  },
];

const check = process.argv.includes('--check');
const stdoutTarget = process.argv.indexOf('--stdout');

function refName(schema, ref) {
  const key = ref.replace('#/$defs/', '');
  return schema.$defs?.[key]?.['x-lua-name'] ?? 'table';
}

function literal(value) {
  return typeof value === 'string' ? `'"${value}"'` : typeof value === 'number' ? 'integer' : 'boolean';
}

function luaType(schema, fragment) {
  if (fragment.$ref) return refName(schema, fragment.$ref);
  if (Object.hasOwn(fragment, 'const')) return literal(fragment.const);
  if (fragment.enum) return fragment.enum.map(literal).join('|');
  if (fragment.oneOf || fragment.anyOf) return (fragment.oneOf ?? fragment.anyOf).map((item) => luaType(schema, item)).join('|');
  if (Array.isArray(fragment.type)) {
    const nullable = fragment.type.includes('null');
    const primary = fragment.type.find((item) => item !== 'null') ?? 'table';
    return `${luaType(schema, { ...fragment, type: primary })}${nullable ? '|nil' : ''}`;
  }
  if (fragment.type === 'array') return `${luaType(schema, fragment.items ?? {})}[]`;
  if (fragment.type === 'integer') return 'integer';
  if (fragment.type === 'number') return 'number';
  if (fragment.type === 'boolean') return 'boolean';
  if (fragment.type === 'string') return 'string';
  return 'table';
}

function emitDefinition(schema, key, definition) {
  const name = definition['x-lua-name'];
  if (!name) return '';
  const lines = [];
  if (definition.description) lines.push(`--- ${definition.description}`);
  if (definition.type === 'object') {
    lines.push(`---@class ${name}`);
    const required = new Set(definition.required ?? []);
    for (const [property, value] of Object.entries(definition.properties ?? {})) {
      lines.push(`---@field ${property}${required.has(property) ? '' : '?'} ${luaType(schema, value)}`);
    }
  } else {
    lines.push(`---@alias ${name} ${luaType(schema, definition)}`);
  }
  return `${lines.join('\n')}\n`;
}

async function render(target) {
  const definitions = new Map();
  for (const relativePath of target.schemas) {
    const schema = JSON.parse(await readFile(resolve(root, relativePath), 'utf8'));
    if (schema['x-lua-name']) {
      const name = schema['x-lua-name'];
      if (definitions.has(name)) throw new Error(`duplicate LuaLS definition ${name}`);
      definitions.set(name, { schema, key: '$root', definition: schema });
    }
    for (const [key, definition] of Object.entries(schema.$defs ?? {})) {
      if (!definition['x-lua-name']) continue;
      const name = definition['x-lua-name'];
      if (definitions.has(name)) throw new Error(`duplicate LuaLS definition ${name}`);
      definitions.set(name, { schema, key, definition });
    }
  }

  const chunks = [
    '---@meta',
    '-- Generated from packages/contracts/schema by scripts/generate-lua-annotations.mjs.',
    '-- Do not hand-edit; run `bun run generate:lua` from packages/contracts.',
    '',
  ];
  for (const { schema, key, definition } of definitions.values()) {
    chunks.push(emitDefinition(schema, key, definition));
  }
  return `${chunks.join('\n').trimEnd()}\n`;
}

if (stdoutTarget >= 0) {
  const output = process.argv[stdoutTarget + 1];
  const target = targets.find((candidate) => candidate.output === output);
  if (!target) throw new Error(`unknown LuaLS output ${output ?? ''}`);
  process.stdout.write(await render(target));
  process.exit(0);
}

let failed = false;
for (const target of targets) {
  const generated = await render(target);
  const destination = resolve(root, target.output);
  if (check) {
    const existing = await readFile(destination, 'utf8').catch(() => '');
    if (existing !== generated) {
      console.error(`${target.output} is stale; run bun run generate:lua`);
      failed = true;
    }
  } else {
    await writeFile(destination, generated);
    console.log(`generated ${target.output}`);
  }
}

if (failed) process.exitCode = 1;
