import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { convertRepo, writeKitSelfTest } from '../lib/convert.js';

function sandbox(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-output-safety-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const source = path.join(dir, 'source');
  fs.mkdirSync(source);
  fs.writeFileSync(path.join(source, 'main.py'), 'print("owner source")\n');
  return { dir, source };
}

test('conversion refuses ancestors and unrelated non-empty output without changing files', (t) => {
  const { dir, source } = sandbox(t);
  fs.mkdirSync(path.join(dir, 'kit'));
  fs.writeFileSync(path.join(dir, 'kit', 'owner.txt'), 'keep');
  assert.throws(() => convertRepo(source, { out: dir }), /must not contain/);
  const out = path.join(dir, 'unrelated');
  fs.mkdirSync(out);
  fs.writeFileSync(path.join(out, 'Package.swift'), 'owner package');
  assert.throws(() => convertRepo(source, { out }), /non-empty output/);
  assert.equal(fs.readFileSync(path.join(source, 'main.py'), 'utf8'), 'print("owner source")\n');
  assert.equal(fs.readFileSync(path.join(dir, 'kit', 'owner.txt'), 'utf8'), 'keep');
  assert.equal(fs.readFileSync(path.join(out, 'Package.swift'), 'utf8'), 'owner package');
});

test('conversion refuses symlink aliases into either side of the source boundary', (t) => {
  const { dir, source } = sandbox(t);
  fs.symlinkSync(source, path.join(dir, 'source-alias'));
  fs.symlinkSync(dir, path.join(dir, 'parent-alias'));
  assert.throws(() => convertRepo(source, { out: path.join(dir, 'source-alias', 'new-output') }), /outside the source/);
  assert.throws(() => convertRepo(source, { out: path.join(dir, 'parent-alias') }), /must not contain/);
  assert.ok(fs.existsSync(path.join(source, 'main.py')));
});

test('conversion allows new output and reconversion for that source only', (t) => {
  const { dir, source } = sandbox(t);
  const out = path.join(dir, 'output');
  convertRepo(source, { out });
  fs.writeFileSync(path.join(source, 'main.py'), 'print("updated")\n');
  convertRepo(source, { out });
  assert.equal(fs.readFileSync(path.join(out, 'app', 'main.py'), 'utf8'), 'print("updated")\n');
  const other = path.join(dir, 'other');
  fs.mkdirSync(other);
  fs.writeFileSync(path.join(other, 'main.py'), 'print("other")');
  assert.throws(() => convertRepo(other, { out }), /non-empty output/);
});

test('self-test preserves unknown output and permits its own generated directory', (t) => {
  const { dir, source } = sandbox(t);
  fs.mkdirSync(path.join(source, 'Sources'));
  fs.writeFileSync(path.join(source, 'Sources', 'owner.swift'), '// preserve');
  assert.throws(() => writeKitSelfTest(source), /non-empty output/);
  assert.equal(fs.readFileSync(path.join(source, 'Sources', 'owner.swift'), 'utf8'), '// preserve');
  const out = path.join(dir, 'selftest');
  writeKitSelfTest(out);
  writeKitSelfTest(out);
  assert.ok(fs.existsSync(path.join(out, 'Sources', 'KitSelfTest', 'main.swift')));
});

test('case aliases on a case-insensitive volume cannot replace source', (t) => {
  const { dir, source } = sandbox(t);
  const alias = path.join(dir, 'SOURCE');
  if (!fs.existsSync(alias)) { t.skip('volume is case-sensitive'); return; }
  assert.throws(() => convertRepo(source, { out: alias }), /outside the source/);
  assert.ok(fs.existsSync(path.join(source, 'main.py')));
});
