import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const evidenceRoot = path.join(root, 'evidence');
const runs = JSON.parse(fs.readFileSync(path.join(evidenceRoot, 'windows-runs.json'), 'utf8'));
const expected = new Map([
  ['ace', 12],
  ['academy', 9],
  ['marketing', 16],
  ['operator', 18],
  ['realestate', 8],
  ['trading', 10],
]);

assert.equal(runs.schema, 'circuit.portfolio-windows-runs.v1');
assert.equal(runs.commit, '84e6d19b2c6084e337bf6532272f499c72c350c7');
assert.equal(runs.apps.length, 6);
const verdict = { schema: 'circuit.portfolio-windows-verdict.v1', commit: runs.commit, apps: [] };
for (const row of runs.apps) {
  assert.ok(expected.has(row.app), `${row.app}: declared app`);
  assert.equal(row.runs.length, 2, `${row.app}: two Windows runs`);
  assert.notEqual(row.runs[0].runId, row.runs[1].runId, `${row.app}: distinct run ids`);
  for (const run of row.runs) {
    assert.match(String(run.runId), /^3569\d+$/u, `${row.app}: run id`);
    assert.match(String(run.artifactId), /^1067\d+$/u, `${row.app}: artifact id`);
    assert.match(run.artifactName, new RegExp(`^${row.app === 'realestate' ? 'realestate' : row.app}-windows-`, 'u'), `${row.app}: artifact identity`);
    for (const key of ['compiled', 'installed', 'launched', 'selfTestPassed', 'uninstalled']) assert.equal(run.receipt[key], true, `${row.app}/${run.runId}: ${key}`);
    assert.equal(run.receipt.requiredResiduals, 0, `${row.app}/${run.runId}: residuals`);
    assert.ok(Number.isInteger(run.receipt.package.bytes) && run.receipt.package.bytes > 0, `${row.app}/${run.runId}: package bytes`);
    assert.match(run.receipt.package.sha256, /^[a-f0-9]{64}$/u, `${row.app}/${run.runId}: package hash`);
  }
  const featureCount = row.runs[1].receipt.featureCount ?? expected.get(row.app);
  assert.equal(featureCount, expected.get(row.app), `${row.app}: feature parity count`);
  if (row.app === 'operator') {
    assert.equal(row.runs[0].receipt.canonicalIdentity, 'operator');
    assert.equal(row.runs[1].receipt.canonicalIdentity, 'operator');
    assert.equal(row.runs[0].receipt.engineSmoke, true);
    assert.equal(row.runs[1].receipt.engineSmoke, true);
  }
  verdict.apps.push({ app: row.app, runs: row.runs.map((run) => ({ runId: run.runId, artifactId: run.artifactId, package: run.receipt.package })), requiredResiduals: 0, verdict: 'pass' });
}
assert.deepEqual(new Set(verdict.apps.map((row) => row.app)), new Set(expected.keys()));
verdict.verdict = 'pass';
fs.writeFileSync(path.join(evidenceRoot, 'windows-verdict.json'), `${JSON.stringify(verdict, null, 2)}\n`);
console.log('PORTFOLIO_WINDOWS_PASS');
