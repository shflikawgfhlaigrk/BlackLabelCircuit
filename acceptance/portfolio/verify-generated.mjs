import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const portfolioRoot = path.dirname(fileURLToPath(import.meta.url));
const acceptanceRoot = path.dirname(portfolioRoot);
const expectedFeatures = new Map([
  ['ace', 12],
  ['academy', 9],
  ['marketing', 16],
  ['operator', 18],
  ['realestate', 8],
  ['trading', 10],
]);

const verdict = { schema: 'circuit.portfolio-generated.v1', apps: [] };
for (const [app, featureCount] of expectedFeatures) {
  const appRoot = path.join(acceptanceRoot, app, 'generated', 'windows-app');
  const manifest = JSON.parse(fs.readFileSync(path.join(appRoot, 'windows-app-manifest.json'), 'utf8'));
  const featureMatrix = JSON.parse(fs.readFileSync(path.join(appRoot, 'feature-matrix.json'), 'utf8'));
  const rows = featureMatrix.features ?? featureMatrix.featureMatrix;
  assert.equal(manifest.generated, true, `${app}: generated`);
  assert.equal(manifest.requiredResiduals, 0, `${app}: manifest residuals`);
  assert.equal(featureMatrix.requiredResiduals, 0, `${app}: feature residuals`);
  assert.equal(rows.length, featureCount, `${app}: feature count`);
  assert.ok(rows.every((row) => row.required === true && row.macSource === true && row.windowsGenerated === true), `${app}: required feature parity`);
  verdict.apps.push({ app, featureCount, requiredResiduals: 0, verdict: 'pass' });
}
verdict.verdict = 'pass';
const evidenceRoot = path.join(portfolioRoot, 'evidence');
fs.mkdirSync(evidenceRoot, { recursive: true });
fs.writeFileSync(path.join(evidenceRoot, 'generated-verdict.json'), `${JSON.stringify(verdict, null, 2)}\n`);
console.log('PORTFOLIO_GENERATED_PASS');
