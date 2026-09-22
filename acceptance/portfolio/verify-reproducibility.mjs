import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const portfolioRoot = path.dirname(fileURLToPath(import.meta.url));
const acceptanceRoot = path.dirname(portfolioRoot);
const apps = ['ace', 'academy', 'marketing', 'operator', 'realestate', 'trading'];

function snapshot(root) {
  const rows = [];
  const visit = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const absolute = path.join(dir, entry.name);
      if (entry.isDirectory()) visit(absolute);
      else if (entry.isFile()) {
        const relative = path.relative(root, absolute).split(path.sep).join('/');
        rows.push({ relative, bytes: fs.statSync(absolute).size, sha256: crypto.createHash('sha256').update(fs.readFileSync(absolute)).digest('hex') });
      }
    }
  };
  visit(root);
  return rows;
}

const verdict = { schema: 'circuit.portfolio-reproducibility.v1', apps: [] };
for (const app of apps) {
  const first = snapshot(path.join(acceptanceRoot, app, 'generated', 'windows-app'));
  const second = snapshot(path.join(acceptanceRoot, app, 'reconverted', 'windows-app'));
  assert.deepEqual(second, first, `${app}: clean conversion output differs`);
  const secondSummary = JSON.parse(fs.readFileSync(path.join(acceptanceRoot, app, 'reconverted', 'second-conversion-summary.json'), 'utf8'));
  assert.match(secondSummary.source.sha256, /^[a-f0-9]{64}$/u, `${app}: source hash`);
  const firstSummaryPath = path.join(acceptanceRoot, app, 'generated', 'conversion-summary.json');
  if (fs.existsSync(firstSummaryPath)) {
    const firstSummary = JSON.parse(fs.readFileSync(firstSummaryPath, 'utf8'));
    assert.equal(secondSummary.source.sha256, firstSummary.source.sha256, `${app}: pinned source identity`);
  }
  assert.equal(secondSummary.windowsApp.requiredResiduals, 0, `${app}: second conversion residuals`);
  verdict.apps.push({ app, sourceSha256: secondSummary.source.sha256, files: first.length, byteIdentical: true, requiredResiduals: 0, verdict: 'pass' });
}
verdict.verdict = 'pass';
const evidenceRoot = path.join(portfolioRoot, 'evidence');
fs.mkdirSync(evidenceRoot, { recursive: true });
fs.writeFileSync(path.join(evidenceRoot, 'reproducibility-verdict.json'), `${JSON.stringify(verdict, null, 2)}\n`);
console.log('PORTFOLIO_REPRODUCIBILITY_PASS');
