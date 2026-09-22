// Stage the Windows UI payload into the Electron app tree.
//
// The A/B against the Tauri shell in ../windows only means anything if BOTH shells carry
// byte-identical content, so this fails closed on any mismatch rather than staging a drifted
// copy. Source of truth is ../windows/ui — the exact directory tauri.conf.json points
// frontendDist at. This script NEVER edits or regenerates that UI.
//
// Unlike the Academy payload this tree is NESTED (ui/vendor/leaflet/…), so the walk is
// recursive; a flat copy would silently drop Leaflet and the map would render empty.
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const SOURCE = join(ROOT, "..", "windows", "ui");
const TARGET = join(ROOT, "app", "ui");

const sha256 = (buffer) => createHash("sha256").update(buffer).digest("hex");

function fail(message) {
  console.error(`stage: ${message}`);
  process.exit(1);
}

function walk(directory) {
  const found = [];
  let entries;
  try { entries = readdirSync(directory, { withFileTypes: true }); }
  catch { fail(`UI payload not found at ${SOURCE}. This shell never generates content.`); }
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const absolute = join(directory, entry.name);
    if (entry.isDirectory()) found.push(...walk(absolute));
    else if (entry.isFile()) found.push(absolute);
  }
  return found;
}

const files = walk(SOURCE);
if (!files.length) fail(`UI payload at ${SOURCE} is empty.`);
const relatives = files.map((absolute) => relative(SOURCE, absolute));
if (!relatives.includes("index.html")) fail("UI payload has no index.html; the shell has nothing to load.");
// Leaflet ships inside the payload precisely so the map does not depend on a CDN at runtime.
// If it ever stops being staged, the map degrades silently — so refuse instead.
if (!relatives.some((name) => name.startsWith(`vendor${sep}leaflet${sep}`))) fail("UI payload is missing vendor/leaflet; the map would not render.");

rmSync(TARGET, { recursive: true, force: true });
mkdirSync(TARGET, { recursive: true });

const manifest = [];
for (const [index, absolute] of files.entries()) {
  const name = relatives[index];
  const destination = join(TARGET, name);
  mkdirSync(dirname(destination), { recursive: true });
  const bytes = readFileSync(absolute);
  writeFileSync(destination, bytes);
  // Read the copy back rather than trusting the write — this hash is the evidence that the
  // Electron artifact and the Tauri artifact carry the same bytes.
  const staged = readFileSync(destination);
  const [sourceHash, stagedHash] = [sha256(bytes), sha256(staged)];
  if (sourceHash !== stagedHash) fail(`staged ${name} does not match the source payload.`);
  manifest.push({ file: name.split(sep).join("/"), bytes: staged.length, sha256: stagedHash });
}

const total = manifest.reduce((sum, row) => sum + row.bytes, 0);
writeFileSync(join(TARGET, "..", "payload-manifest.json"), `${JSON.stringify({
  source: "windows/ui",
  staged_at_utc: new Date().toISOString(),
  total_bytes: total,
  files: manifest,
}, null, 2)}\n`);

console.log(`stage: ${manifest.length} file(s), ${total} bytes — byte-identical to the Tauri payload.`);
