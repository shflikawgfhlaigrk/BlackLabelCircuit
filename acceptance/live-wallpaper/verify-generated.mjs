import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const generated = path.join(root, 'generated');
const conversion = JSON.parse(fs.readFileSync(path.join(generated, 'conversion.json')));
const manifest = JSON.parse(fs.readFileSync(path.join(generated, 'windows-app', 'windows-app-manifest.json')));
const receipt = JSON.parse(fs.readFileSync(path.join(root, 'evidence', 'generation-receipt.json')));
assert.equal(conversion.source.sha256, receipt.sourceSha256);
assert.equal(conversion.source.files, 1);
assert.equal(conversion.totals.all.loc, 561);
assert.equal(manifest.generated, true);
assert.equal(manifest.requiredResiduals, 0);
assert.equal(manifest.featureMatrix.length, 10);
assert.ok(manifest.featureMatrix.every((row) => row.required && row.macSource && row.windowsGenerated));
const asset = fs.readFileSync(path.join(generated, 'windows-app', 'Assets', 'wallpaper.png'));
assert.equal(crypto.createHash('sha256').update(asset).digest('hex'), receipt.assetSha256);
console.log('GENERATION_PASS');

