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
const partsManifest = JSON.parse(fs.readFileSync(path.join(root, 'evidence', 'package-parts.json')));
assert.equal(partsManifest.bytes, evidence.package.bytes);
assert.equal(partsManifest.sha256, evidence.package.sha256);
const packageHash = crypto.createHash('sha256');
let packageBytes = 0;
for (const part of partsManifest.parts) {
  const partBytes = fs.readFileSync(path.join(root, 'evidence', part.path));
  assert.equal(partBytes.length, part.bytes, `${part.path} bytes`);
  assert.equal(crypto.createHash('sha256').update(partBytes).digest('hex'), part.sha256, `${part.path} sha256`);
  packageHash.update(partBytes);
  packageBytes += partBytes.length;
}
assert.equal(packageBytes, evidence.package.bytes);
assert.equal(packageHash.digest('hex'), evidence.package.sha256);
console.log('WINDOWS_ACCEPTANCE_PASS');
