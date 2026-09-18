#!/usr/bin/env node
// Black Label Real Estate — MSIX Store tile generator.
//
// Emits every PNG the AppxManifest declares, at its EXACT required pixel dimensions, so the
// package layout is genuinely makeappx-packable. makeappx REJECTS a missing or non-PNG asset,
// which would otherwise fail the pack only after a full 10-minute Rust/Tauri build.
//
// These are honest PLACEHOLDER tiles rendered from the app's OWN mark (assets/app-mark.svg:
// gold hex frame + house glyph on near-black). Brand-isolation safe — no other property's
// name, mark or domain appears, and PNG text-bearing metadata chunks are gated out below so a
// rasteriser can never smuggle a cross-brand string into a shipped tile.
//
// Final Store art is a design deliverable that drops in over the SAME filenames.
//
// Zero runtime deps — PNG is hand-encoded via node:zlib. No image library, no network.
//
//   node windows/msix/gen-assets.mjs               write every tile into ./Assets
//   node windows/msix/gen-assets.mjs --check       full gate: signature + exact dims + no text chunks
//   node windows/msix/gen-assets.mjs --check-basic existence probe only (placeholder bootstrap)
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ASSETS = path.join(HERE, 'Assets');

// Every asset referenced by windows/msix/AppxManifest.xml, at its Microsoft-spec dimensions.
// If you add a Logo reference to the manifest, add it here or the pre-pack gate will catch it.
export const TILES = [
  { name: 'StoreLogo.png', w: 50, h: 50 },
  { name: 'Square44x44Logo.png', w: 44, h: 44 },
  { name: 'Square71x71Logo.png', w: 71, h: 71 },
  { name: 'Square150x150Logo.png', w: 150, h: 150 },
  { name: 'Square310x310Logo.png', w: 310, h: 310 },
  { name: 'Wide310x150Logo.png', w: 310, h: 150 },
  { name: 'SplashScreen.png', w: 620, h: 300 },
];

const BG = [0x0a, 0x0a, 0x0b];   // near-black ground
const GOLD = [0xd4, 0xaf, 0x37]; // primary gold (matches app-mark.svg mid stop)
const LIGHT = [0xf9, 0xe2, 0x7d]; // highlight gold

// The app mark in normalized [0,1] coords: outer hex frame, inner hex, house glyph.
const HEX_OUT = [[0.50, 0.06], [0.89, 0.28], [0.89, 0.72], [0.50, 0.94], [0.11, 0.72], [0.11, 0.28]];
const HEX_IN = [[0.50, 0.16], [0.79, 0.32], [0.79, 0.68], [0.50, 0.84], [0.21, 0.68], [0.21, 0.32]];
const HOUSE = [
  [[0.38, 0.50], [0.50, 0.39]], [[0.50, 0.39], [0.62, 0.50]],   // roof
  [[0.41, 0.475], [0.41, 0.61]], [[0.41, 0.61], [0.59, 0.61]],  // walls + floor
  [[0.59, 0.61], [0.59, 0.475]],
  [[0.47, 0.61], [0.47, 0.54]], [[0.47, 0.54], [0.53, 0.54]],   // door
  [[0.53, 0.54], [0.53, 0.61]],
];

// ---- raw RGBA canvas ----------------------------------------------------------------------
function canvas(w, h) {
  const px = Buffer.alloc(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    px[i * 4] = BG[0]; px[i * 4 + 1] = BG[1]; px[i * 4 + 2] = BG[2]; px[i * 4 + 3] = 0xff;
  }
  return px;
}
function put(px, w, h, x, y, c) {
  x = Math.round(x); y = Math.round(y);
  if (x < 0 || y < 0 || x >= w || y >= h) return;
  const i = (y * w + x) * 4;
  px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 0xff;
}
function disc(px, w, h, cx, cy, r, c) {
  for (let y = Math.floor(cy - r); y <= Math.ceil(cy + r); y++)
    for (let x = Math.floor(cx - r); x <= Math.ceil(cx + r); x++)
      if ((x - cx) ** 2 + (y - cy) ** 2 <= r * r) put(px, w, h, x, y, c);
}
function line(px, w, h, x0, y0, x1, y1, c, thick) {
  const steps = Math.ceil(Math.hypot(x1 - x0, y1 - y0)) * 2 + 1;
  for (let s = 0; s <= steps; s++) {
    const t = s / steps;
    disc(px, w, h, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, thick, c);
  }
}
// Draw a closed polygon given normalized points, fitted into a centred square of side `m`.
function poly(px, w, h, pts, c, thick, m, ox, oy) {
  for (let i = 0; i < pts.length; i++) {
    const a = pts[i], b = pts[(i + 1) % pts.length];
    line(px, w, h, ox + a[0] * m, oy + a[1] * m, ox + b[0] * m, oy + b[1] * m, c, thick);
  }
}
function render(w, h) {
  const px = canvas(w, h);
  // Fit the square mark into the shorter axis with a small margin, centred on both axes.
  const m = Math.min(w, h) * 0.92;
  const ox = (w - m) / 2, oy = (h - m) / 2;
  const stroke = Math.max(0.45, m * 0.014);
  poly(px, w, h, HEX_OUT, GOLD, stroke, m, ox, oy);
  poly(px, w, h, HEX_IN, LIGHT, stroke * 0.85, m, ox, oy);
  for (const [a, b] of HOUSE) {
    line(px, w, h, ox + a[0] * m, oy + a[1] * m, ox + b[0] * m, oy + b[1] * m, LIGHT, stroke * 0.9);
  }
  return px;
}

// ---- PNG encode (truecolor+alpha, filter 0) -----------------------------------------------
const CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td), 0);
  return Buffer.concat([len, td, crc]);
}
export function encodePNG(w, h, rgba) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0; // 8-bit RGBA
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) {
    raw[y * (1 + w * 4)] = 0; // filter: none
    rgba.copy(raw, y * (1 + w * 4) + 1, y * w * 4, (y + 1) * w * 4);
  }
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

export function readPngDims(file) {
  const b = fs.readFileSync(file);
  const sigOk = b.length >= 24 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;
  if (!sigOk) return { sigOk: false };
  return { sigOk: true, w: b.readUInt32BE(16), h: b.readUInt32BE(20) };
}

// Ancillary PNG chunks that can carry free text (author, software, comment, source path) and so
// can leak a cross-brand string into a shipped Store tile. Colour/render chunks (sRGB, gAMA,
// pHYs) are string-free and stay allowed. External rasterisers add eXIf routinely.
const TEXTY_CHUNKS = new Set(['tEXt', 'iTXt', 'zTXt', 'eXIf', 'tIME']);

export function pngChunkTypes(file) {
  const b = fs.readFileSync(file);
  const types = [];
  let o = 8;
  while (o + 12 <= b.length) { types.push(b.toString('ascii', o + 4, o + 8)); o += 12 + b.readUInt32BE(o); }
  return types;
}

function main() {
  const check = process.argv.includes('--check');
  const basic = process.argv.includes('--check-basic');
  if (check || basic) {
    let bad = 0;
    for (const { name, w, h } of TILES) {
      const f = path.join(ASSETS, name);
      if (!fs.existsSync(f)) { console.error(`MISSING ${name}`); bad++; continue; }
      const d = readPngDims(f);
      if (!d.sigOk) { console.error(`NOT A PNG ${name}`); bad++; continue; }
      if (basic) { console.log(`present ${name}`); continue; }
      if (d.w !== w || d.h !== h) { console.error(`WRONG DIMS ${name}: ${d.w}x${d.h} != ${w}x${h}`); bad++; continue; }
      const texty = pngChunkTypes(f).filter((t) => TEXTY_CHUNKS.has(t));
      if (texty.length) { console.error(`METADATA CHUNKS ${name}: ${texty.join(',')} (strip before packing)`); bad++; continue; }
      const sha = crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
      console.log(`ok ${name} ${d.w}x${d.h} sha256=${sha}`);
    }
    process.exit(bad ? 1 : 0);
  }
  fs.mkdirSync(ASSETS, { recursive: true });
  for (const { name, w, h } of TILES) {
    fs.writeFileSync(path.join(ASSETS, name), encodePNG(w, h, render(w, h)));
    console.log(`wrote ${name} ${w}x${h}`);
  }
}

// Compare REAL paths. A raw `file://${process.argv[1]}` comparison mismatches whenever the script
// is reached through a symlinked ancestor (macOS /tmp and /var/folders, a CI checkout under a
// symlink) and the failure is SILENT: main() never runs, the gate prints nothing and exits 0 —
// a fail-open gate. Callers must be able to trust a zero exit here.
const invoked = process.argv[1] ? fs.realpathSync(process.argv[1]) : '';
if (invoked === fs.realpathSync(fileURLToPath(import.meta.url))) main();
