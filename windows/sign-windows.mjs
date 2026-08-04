#!/usr/bin/env node
// Authenticode sign gate — FAIL-CLOSED. SIDELOAD-TEST-ONLY under the Store-first amendment.
//
// LAW (contract windows-w1-circuit-20260720, founder amendment 2026-07-20 ~09:05Z):
// distribution is STORE-FIRST via MSIX and the Microsoft Store RE-SIGNS the uploaded package —
// so the Store path buys/applies NO Authenticode cert and stages the .msix UNSIGNED. This gate
// is invoked ONLY by `build-msix.sh --sideload` to self-sign an MSIX for LOCAL sideload testing
// (and by the legacy NSIS direct-download fallback). It MUST refuse to sign and publish nothing
// unless a real cert is present — an unsigned sideload artifact must never masquerade as signed.
//
//   node windows/sign-windows.mjs <path-to-installer>
//
// Exit codes:  0 = artifact signed and verified   (only reachable with a real cert)
//              3 = GATE HELD — no cert, nothing signed, nothing published (expected today)
//              2 = usage / environment error
//
// A real cert is provided out-of-band by the founder as:
//   CIRCUIT_WIN_CERT           absolute path to the .pfx (must exist & be non-empty)
//   CIRCUIT_WIN_CERT_PASSWORD  its password
// The gate NEVER treats a missing/empty/placeholder cert as signable.
import fs from 'node:fs';
import os from 'node:os';
import { spawnSync } from 'node:child_process';

const artifact = process.argv[2];
if (!artifact) {
  console.error('[sign] usage: node windows/sign-windows.mjs <path-to-installer>');
  process.exit(2);
}

const HELD = 3;
function hold(reason) {
  console.error(`[sign] GATE HELD — ${reason}`);
  console.error('[sign] No artifact was signed or published. Unsigned == unshippable.');
  console.error('[sign] The Authenticode cert is a founder money-gate (expected 2026-07-21).');
  process.exit(HELD);
}

const certPath = process.env.CIRCUIT_WIN_CERT;
const certPass = process.env.CIRCUIT_WIN_CERT_PASSWORD;

// Fail closed on every way the cert can be absent or fake.
if (!certPath) hold('CIRCUIT_WIN_CERT is not set (no signing certificate).');
if (!fs.existsSync(certPath)) hold(`certificate not found at ${certPath}.`);
const certStat = fs.statSync(certPath);
if (!certStat.isFile() || certStat.size === 0) hold(`certificate at ${certPath} is empty or not a file.`);
if (!certPass) hold('CIRCUIT_WIN_CERT_PASSWORD is not set.');
if (!fs.existsSync(artifact)) {
  console.error(`[sign] artifact not found: ${artifact}`);
  process.exit(2);
}

// signtool is Windows-only; on any other host we cannot sign — hold, never fake it.
if (os.platform() !== 'win32') {
  hold(`signing requires Windows signtool (host is ${os.platform()}).`);
}

// --- Post-cert path (reachable only in the VM, with a real cert) ---------------
console.log(`[sign] signing ${artifact} with ${certPath} …`);
const sign = spawnSync('signtool', [
  'sign', '/fd', 'sha256', '/tr', 'http://timestamp.digicert.com', '/td', 'sha256',
  '/f', certPath, '/p', certPass, artifact,
], { stdio: 'inherit' });
if (sign.status !== 0) {
  console.error('[sign] signtool failed — artifact NOT signed.');
  process.exit(sign.status ?? 2);
}
const verify = spawnSync('signtool', ['verify', '/pa', '/v', artifact], { stdio: 'inherit' });
if (verify.status !== 0) {
  console.error('[sign] signature verification failed.');
  process.exit(verify.status ?? 2);
}
console.log('[sign] signed and verified.');
process.exit(0);
