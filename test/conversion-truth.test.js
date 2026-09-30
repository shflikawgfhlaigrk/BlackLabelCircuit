import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { formatConvertMarkdown, formatConvertReport } from '../lib/convert.js';

function fixture(verification, windowsApp = { generated: false, kind: 'unclassified', residuals: [{ feature: 'windowsApplication' }] }) {
  return {
    name: 'Sunset', target: 'Windows', root: '/owned/sunset', out: '/converted/sunset', generatedAt: 0,
    verification, windowsApp, before: { readyPct: 50 }, windowsPartsNeeded: [],
    packages: [], skipped: [], files: [], kit: false,
    totals: {
      all: { files: 75, loc: 20597 }, portable: { files: 42, loc: 8752 },
      converted: { files: 4, loc: 1424 }, partial: { files: 8, loc: 2188, buildsLoc: 1002, isolatedLoc: 1186 },
      needsWindowsPart: { files: 21, loc: 8233 }, macOnlySkipped: { files: 0, loc: 0 },
      unverified: { files: 0, loc: 0 }, buildsLoc: 11178, buildsForWindowsPct: 54.3,
    },
  };
}

test('Mac simulation and missing application are explicit in CLI and Markdown receipts', () => {
  const result = fixture({ ran: true, ok: true, native: false, platform: 'darwin',
    configuration: 'simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM)',
    swift: 'Swift 6.4', passes: [{ pass: 1 }] });
  const cli = formatConvertReport(result);
  const markdown = formatConvertMarkdown(result);
  assert.match(cli, /54\.3%.*simulated Windows configuration on macOS/);
  assert.match(cli, /Native Windows application and installer unverified/);
  assert.match(cli, /Windows app status: not generated; 1 required residual/);
  assert.doesNotMatch(cli, /54\.3%.*builds for Windows/);
  assert.match(markdown, /Mac simulation does not verify a Windows application or installer/);
  assert.match(markdown, /No Windows application was generated/);
  assert.match(markdown, /converted package is not a runnable Windows app/);
  assert.doesNotMatch(markdown, /54\.3% of the app code builds for Windows/);
});

test('native package compile still leaves application acceptance open', () => {
  const result = fixture({ ran: true, ok: true, native: true, platform: 'win32',
    configuration: 'native Windows build', swift: 'Swift 6.4', passes: [{ pass: 1 }] },
  { generated: true, kind: 'sunset', featureMatrix: [{ feature: 'audioExport' }], requiredResiduals: 0 });
  const cli = formatConvertReport(result);
  const markdown = formatConvertMarkdown(result);
  assert.match(cli, /compiled in the native Windows package check/);
  assert.match(cli, /This does not verify the application or installer/);
  assert.match(cli, /Windows app status: generated — real-Windows compile\/install\/launch acceptance is still required/);
  assert.match(markdown, /Application compile, install, launch and feature parity require separate evidence/);
});

test('missing native provenance cannot earn a native Windows claim', () => {
  const result = fixture({ ran: true, ok: true, configuration: 'Windows-like build', passes: [{ pass: 1 }] });
  assert.match(formatConvertReport(result), /Native Windows application and installer unverified/);
  assert.doesNotMatch(formatConvertReport(result), /compiled in the native Windows package check/);
});

test('buyer UI exposes generation status and no longer promises every source file builds for Windows', () => {
  const script = fs.readFileSync(new URL('../public/app.js', import.meta.url), 'utf8');
  const html = fs.readFileSync(new URL('../public/index.html', import.meta.url), 'utf8');
  assert.match(script, /No Windows application generated/);
  assert.match(script, /Native Windows application and installer unverified/);
  assert.match(script, /Starting an online conversion sends a minimized source bundle/);
  assert.match(script, /chip\.textContent = '⏚ local analysis'/);
  assert.doesNotMatch(script, /offline — no code leaves this machine/);
  assert.doesNotMatch(html, /your compiler checks every file/);
});
