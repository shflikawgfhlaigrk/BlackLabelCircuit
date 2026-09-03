#!/usr/bin/env node
// Circuit-Win shell icon generator — windows/src-tauri/icons/icon.ico.
//
// tauri-build REQUIRES a .ico when it targets Windows: it compiles a resource file (tauri-winres ->
// rc.exe) for the exe and aborts the whole build with
//   "`icons/icon.ico` not found; required for generating a Windows Resource file during tauri-build"
// when the file is absent (tauri-build 2.6.x, src/lib.rs). The same file is the exe's Explorer /
// taskbar icon, and its FIRST entry becomes the runtime window icon (tauri-codegen embeds entry 0).
//
// Same motif, same zero-dependency raster as the Store tiles (gen-assets.mjs). The container holds
// classic 32-bit BGRA bitmaps (AND mask included) at 32/16/48/64 plus one PNG-compressed 256x256
// entry — the Vista+ layout that rc.exe and the Rust `ico` crate both accept. Honest PLACEHOLDER
// art, exactly like the tiles: final Windows art is a founder deliverable that drops in over the
// same filename; --check only proves the container is well-formed, never that it is THIS motif.
//
//   node windows/msix/gen-icon.mjs          # (re)write windows/src-tauri/icons/icon.ico
//   node windows/msix/gen-icon.mjs --check  # verify the committed .ico is a well-formed ICO (exit 1 otherwise)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { encodePNG, render } from './gen-assets.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ICON = path.join(HERE, '..', 'src-tauri', 'icons', 'icon.ico');

// Entry 0 is the window icon tauri embeds; 32px is what a Windows title bar / taskbar wants.
export const SIZES = [32, 16, 48, 64, 256];

// ---- classic ICO bitmap entry: BITMAPINFOHEADER + bottom-up BGRA rows + 1-bit AND mask --------
function bmpEntry(w, h, rgba) {
  const maskRow = Math.ceil(w / 32) * 4; // mask rows are padded to 32 bits
  const hdr = Buffer.alloc(40);
  hdr.writeUInt32LE(40, 0);
  hdr.writeInt32LE(w, 4);
  hdr.writeInt32LE(h * 2, 8); // XOR + AND heights, per the ICO spec
  hdr.writeUInt16LE(1, 12);
  hdr.writeUInt16LE(32, 14);
  hdr.writeUInt32LE(0, 16); // BI_RGB
  hdr.writeUInt32LE(w * h * 4 + maskRow * h, 20);
  const xor = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) {
    const src = (h - 1 - y) * w * 4; // bottom-up
    for (let x = 0; x < w; x++) {
      const s = src + x * 4, d = (y * w + x) * 4;
      xor[d] = rgba[s + 2]; xor[d + 1] = rgba[s + 1]; xor[d + 2] = rgba[s]; xor[d + 3] = rgba[s + 3];
    }
  }
  return Buffer.concat([hdr, xor, Buffer.alloc(maskRow * h, 0)]); // mask 0 = opaque
}

export function encodeICO(sizes = SIZES) {
  const images = sizes.map((s) => (s >= 256 ? encodePNG(s, s, render(s, s)) : bmpEntry(s, s, render(s, s))));
  const dir = Buffer.alloc(6);
  dir.writeUInt16LE(0, 0); dir.writeUInt16LE(1, 2); dir.writeUInt16LE(sizes.length, 4);
  const entries = [];
  let offset = 6 + 16 * sizes.length;
  sizes.forEach((s, i) => {
    const e = Buffer.alloc(16);
    e[0] = s >= 256 ? 0 : s; e[1] = s >= 256 ? 0 : s; e[2] = 0; e[3] = 0;
    e.writeUInt16LE(1, 4); e.writeUInt16LE(32, 6);
    e.writeUInt32LE(images[i].length, 8); e.writeUInt32LE(offset, 12);
    offset += images[i].length;
    entries.push(e);
  });
  return Buffer.concat([dir, ...entries, ...images]);
}

// Structural read-back: ICONDIR header, every entry inside the file, each image a 32-bit BMP or a
// PNG whose declared size matches its directory entry. Returns the entry sizes; throws on drift.
export function readICO(file) {
  const b = fs.readFileSync(file);
  if (b.length < 6 || b.readUInt16LE(0) !== 0 || b.readUInt16LE(2) !== 1) throw new Error('not an ICO (bad ICONDIR)');
  const count = b.readUInt16LE(4);
  if (count < 1 || b.length < 6 + 16 * count) throw new Error('ICONDIR entry table truncated');
  const out = [];
  for (let i = 0; i < count; i++) {
    const e = 6 + 16 * i;
    const w = b[e] || 256, h = b[e + 1] || 256;
    const size = b.readUInt32LE(e + 8), off = b.readUInt32LE(e + 12);
    if (off + size > b.length) throw new Error(`entry ${i} (${w}x${h}) points past EOF`);
    const img = b.subarray(off, off + size);
    if (img[0] === 0x89 && img[1] === 0x50 && img[2] === 0x4e && img[3] === 0x47) {
      if (img.readUInt32BE(16) !== w || img.readUInt32BE(20) !== h) throw new Error(`entry ${i}: PNG dims != ${w}x${h}`);
      out.push({ w, h, kind: 'png' });
    } else {
      if (img.readUInt32LE(0) !== 40 || img.readInt32LE(4) !== w || img.readInt32LE(8) !== h * 2 || img.readUInt16LE(14) !== 32) {
        throw new Error(`entry ${i}: not a 32-bit ${w}x${h} BITMAPINFOHEADER bitmap`);
      }
      out.push({ w, h, kind: 'bmp' });
    }
  }
  return out;
}

function main() {
  if (process.argv.includes('--check')) {
    if (!fs.existsSync(ICON)) { console.error(`MISSING ${ICON} — cargo tauri build aborts without it`); process.exit(1); }
    try {
      const entries = readICO(ICON);
      console.log(`ok icon.ico ${entries.map((e) => `${e.w}x${e.h}/${e.kind}`).join(' ')}`);
      process.exit(0);
    } catch (e) {
      console.error(`BAD ICO ${ICON}: ${e.message}`);
      process.exit(1);
    }
  }
  fs.mkdirSync(path.dirname(ICON), { recursive: true });
  const ico = encodeICO();
  fs.writeFileSync(ICON, ico);
  console.log(`wrote ${ICON} bytes=${ico.length} entries=${SIZES.join(',')}`);
}

// Real-path entrypoint compare (same reason as gen-assets.mjs: a symlinked cwd must not skip main()).
const invoked = process.argv[1] ? fs.realpathSync(process.argv[1]) : '';
if (invoked === fs.realpathSync(fileURLToPath(import.meta.url))) main();
