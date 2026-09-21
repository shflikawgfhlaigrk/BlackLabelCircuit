import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { convertSwiftSource, runKitSelfTest } from '../lib/convert.js';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

test('supported Foundation Process lifecycle rewrites to CircuitProcess', () => {
  const source = 'import Foundation\nlet p = Process()\np.executableURL = URL(fileURLWithPath: "/usr/bin/true")\ntry p.run()\np.waitUntilExit()\n';
  const result = convertSwiftSource(source);
  assert.match(result.text, /^import CircuitPortKit$/m);
  assert.match(result.text, /let p = CircuitProcess\(\)/);
  assert.ok(result.needsKit);
  assert.ok(result.changes.some((change) => change.kind === 'process-pack'));
  assert.equal(convertSwiftSource(result.text).text, result.text);
});

test('unsupported streams and custom Process types are never silently rewritten', () => {
  const stream = convertSwiftSource('import Foundation\nlet p = Process()\np.standardOutput = Pipe()\n');
  assert.doesNotMatch(stream.text, /CircuitProcess/);
  const custom = convertSwiftSource('struct Process {}\nlet p = Process()\n');
  assert.doesNotMatch(custom.text, /CircuitProcess/);
});

test('process pack contains a Win32 backend and compiles in the kit self-test package', { timeout: 600_000 }, (t) => {
  const source = fs.readFileSync(path.join(ROOT, 'lib', 'convert-kit', 'CircuitPortKit', 'Process.swift'), 'utf8');
  for (const symbol of ['CreateProcessW', 'CREATE_UNICODE_ENVIRONMENT', 'windowsEnvironmentBlock', 'WaitForSingleObject', 'GetExitCodeProcess', 'TerminateProcess', 'CloseHandle']) assert.match(source, new RegExp(symbol));
  const result = runKitSelfTest(fs.mkdtempSync('/tmp/circuit-process-pack-'));
  if (result.spawnError) { t.skip(result.spawnError); return; }
  assert.equal(result.ok, true, result.output);
});
