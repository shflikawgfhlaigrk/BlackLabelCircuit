import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const evidence = JSON.parse(fs.readFileSync(path.join(root, 'evidence', 'reproducibility.json')));
assert.equal(evidence.sourceSha256First, evidence.sourceSha256Second);
assert.equal(evidence.workspaceSha256First, evidence.workspaceSha256Second);
assert.equal(evidence.byteIdentical, true);
assert.equal(evidence.requiredResidualsFirst, 0);
assert.equal(evidence.requiredResidualsSecond, 0);
assert.equal(evidence.secondOutputWasEmpty, true);
console.log('REPRODUCIBILITY_PASS');
