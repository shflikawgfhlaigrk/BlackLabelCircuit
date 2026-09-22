import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const evidence = JSON.parse(fs.readFileSync(path.join(root, 'evidence', 'windows-acceptance.json')));
for (const key of ['compiled', 'installed', 'launched', 'selfTestPassed', 'uninstalled', 'workerCleanup']) assert.equal(evidence[key], true, key);
assert.equal(evidence.requiredResiduals, 0);
assert.equal(evidence.workerCanaries, 3);
assert.ok(Object.values(evidence.featureChecks).every(Boolean));
assert.match(evidence.smoke, /windows=[1-9].*visible=[1-9].*image_loaded=true/);
const artifact = fs.readFileSync(path.join(root, evidence.package.path));
assert.equal(artifact.length, evidence.package.bytes);
assert.equal(crypto.createHash('sha256').update(artifact).digest('hex'), evidence.package.sha256);
console.log('WINDOWS_ACCEPTANCE_PASS');

