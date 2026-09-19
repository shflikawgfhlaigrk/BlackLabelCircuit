#!/usr/bin/env node
// Circuit-Win MSIX Store tile generator — contract windows-w1-circuit-20260720.
//
// Emits the four Store-required PNG tiles at their EXACT pixel dimensions so the MSIX layout is
// actually makeappx-packable (the prior build staged TEXT files named "*.png" — makeappx rejects
// those, failing the pack after a full cargo build in the VM). These are honest PLACEHOLDER tiles:
// a brand-neutral node-graph motif (apt for Circuit's own brand — no other property's name/mark,
// brand-isolation-safe) on a dark ground. Final Store art is a web-producer + founder deliverable;
// this only guarantees a format/dimension-valid layout so the VM pack cannot fail on the assets.
//
// Zero runtime deps (Circuit backend discipline): PNG is hand-encoded via Node's zlib. No image lib.
//
//   node windows/msix/gen-assets.mjs            # write the four tiles into ./Assets
//   node windows/msix/gen-assets.mjs --check    # verify existing tiles match spec (exit 1 on drift)
//   node windows/msix/gen-assets.mjs --check-basic  # existence probe only (placeholder bootstrap)
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ASSETS = path.join(HERE, 'Assets');

// The four Store-required tiles and their exact dimensions (Microsoft Store / makeappx spec).
export const TILES = [
  { name: 'StoreLogo.png', w: 50, h: 50 },
  { name: 'Square44x44Logo.png', w: 44, h: 44 },
  { name: 'Square150x150Logo.png', w: 150, h: 150 },
  { name: 'Wide310x150Logo.png', w: 310, h: 150 },
];

const BG = [0x0b, 0x0e, 0x14]; // near-black ground
const EDGE = [0x2f, 0x4a, 0x63]; // muted steel edge
const NODE = [0x5e, 0xc8, 0xff]; // cyan accent node

// A tiny fixed graph in normalized [0,1] coords — a literal "circuit" of nodes + edges.
const GRAPH = {
  nodes: [
    [0.28, 0.30], [0.66, 0.24], [0.50, 0.52],
    [0.30, 0.72], [0.74, 0.70],
  ],
  edges: [[0, 2], [1, 2], [2, 3], [2, 4], [0, 3], [1, 4]],
};

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
export function render(w, h) {
  const px = canvas(w, h);
  const m = Math.min(w, h);
  const pt = (n) => [GRAPH.nodes[n][0] * w, GRAPH.nodes[n][1] * h];
  const edgeW = Math.max(0.4, m * 0.012);
  const nodeR = Math.max(1.0, m * 0.05);
  for (const [a, b] of GRAPH.edges) { const [ax, ay] = pt(a), [bx, by] = pt(b); line(px, w, h, ax, ay, bx, by, EDGE, edgeW); }
  for (let n = 0; n < GRAPH.nodes.length; n++) { const [x, y] = pt(n); disc(px, w, h, x, y, nodeR, NODE); }
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

// Read IHDR width/height + PNG signature from a file (used by --check and the test suite).
export function readPngDims(file) {
  const b = fs.readFileSync(file);
  const sigOk = b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;
  if (!sigOk) return { sigOk: false };
  return { sigOk: true, w: b.readUInt32BE(16), h: b.readUInt32BE(20) };
}

// Ancillary PNG chunks that can carry free text (author, software, comments, source paths) and so
// can leak a cross-brand string into a shipped Store tile. Colour/render chunks (sRGB, gAMA, pHYs)
// are string-free and stay allowed. External rasterisers (sips, rsvg) add eXIf routinely.
const TEXTY_CHUNKS = new Set(['tEXt', 'iTXt', 'zTXt', 'eXIf', 'tIME']);

export function pngChunkTypes(file) {
  const b = fs.readFileSync(file);
  const types = [];
  let o = 8;
  while (o + 12 <= b.length) { types.push(b.toString('ascii', o + 4, o + 8)); o += 12 + b.readUInt32BE(o); }
  return types;
}

function main() {
  // --check       full gate: signature + spec dimensions + no text-bearing metadata chunks.
  // --check-basic bootstrap probe only: does a real PNG exist at each path? Callers use this to
  //               decide whether to mint placeholders, so it must NOT fail on final art.
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

// Compare REAL paths. A raw `file://${process.argv[1]}` comparison mismatches whenever the script is
// reached through a symlinked ancestor (macOS /tmp and /var/folders, a CI checkout under a symlink),
// and the failure mode is silent: main() never runs, the tile gate prints nothing and exits 0 — a
// fail-open gate. Callers must be able to trust a zero exit here.
const invoked = process.argv[1] ? fs.realpathSync(process.argv[1]) : '';
if (invoked === fs.realpathSync(fileURLToPath(import.meta.url))) main();
