#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const source = path.dirname(fileURLToPath(import.meta.url));
const destination = process.argv[2] && path.resolve(process.argv[2]);
if (!destination || destination === source || destination.startsWith(source + path.sep)) {
  throw new Error('Pass a new extension directory outside the Circuit source tree.');
}
if (fs.existsSync(destination) && fs.readdirSync(destination).length) {
  throw new Error('The extension directory must be empty; existing files were preserved.');
}
fs.mkdirSync(destination, { recursive: true });
fs.cpSync(source, destination, { recursive: true });
fs.cpSync(path.join(source, '..', 'lib'), path.join(destination, 'lib'), { recursive: true });
fs.writeFileSync(path.join(destination, 'lib', 'package.json'), '{"type":"module"}\n');
console.log(`Circuit editor installed at ${destination}`);
