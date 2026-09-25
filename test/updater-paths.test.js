import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
test('updater treats archive filenames as data and restores failed swaps', () => {
  const result=spawnSync('python3',[fileURLToPath(new URL('./test_updater_paths.py',import.meta.url))],{encoding:'utf8',timeout:20000});
  assert.equal(result.status,0,result.stderr || result.error?.message);
});
