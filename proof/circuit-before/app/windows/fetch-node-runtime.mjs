#!/usr/bin/env node
// Fetch the official Windows x64 node.exe and place it as the Tauri sidecar
//   windows/src-tauri/binaries/node-x86_64-pc-windows-msvc.exe
// (Tauri requires the target-triple suffix on external binaries.)
//
// This is BUILD tooling — a network download of the node runtime we bundle. It is
// not part of the shipped app, which makes zero outbound calls (air-gap posture).
// Runs in the W0 VM; also runnable on darwin (it only downloads a file, never
// executes it). Pin the version with CIRCUIT_WIN_NODE (default below).
//
//   node windows/fetch-node-runtime.mjs
import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const NODE_VERSION = process.env.CIRCUIT_WIN_NODE ?? 'v20.18.1';
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BIN_DIR = path.join(__dirname, 'src-tauri', 'binaries');
const TARGET = path.join(BIN_DIR, 'node-x86_64-pc-windows-msvc.exe');
const url = `https://nodejs.org/dist/${NODE_VERSION}/win-x64/node.exe`;

function download(u, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    https.get(u, (res) => {
      if (res.statusCode === 301 || res.statusCode === 302) {
        file.close();
        return download(res.headers.location, dest).then(resolve, reject);
      }
      if (res.statusCode !== 200) {
        file.close();
        return reject(new Error(`HTTP ${res.statusCode} for ${u}`));
      }
      res.pipe(file);
      file.on('finish', () => file.close(resolve));
    }).on('error', (e) => { file.close(); fs.rmSync(dest, { force: true }); reject(e); });
  });
}

fs.mkdirSync(BIN_DIR, { recursive: true });
console.log(`[fetch-node] downloading ${url}`);
await download(url, TARGET);
const buf = fs.readFileSync(TARGET);
const sha = crypto.createHash('sha256').update(buf).digest('hex');
// A Windows PE starts with "MZ" — cheap proof we got a real exe, not an error page.
if (buf.length < 1_000_000 || buf[0] !== 0x4d || buf[1] !== 0x5a) {
  fs.rmSync(TARGET, { force: true });
  throw new Error(`downloaded file is not a Windows PE (bytes=${buf.length}) — refusing to stage a bogus sidecar`);
}
console.log(`[fetch-node] wrote ${TARGET}`);
console.log(`[fetch-node] bytes=${buf.length} sha256=${sha}`);
console.log(`[fetch-node] node ${NODE_VERSION} staged as the Tauri sidecar.`);
