#!/usr/bin/env node
// One-shot Windows diagnostic: dump how the fixture repo is discovered and how
// each Python/JS import resolves, so we can see the exact separator behaviour on
// a real Windows runner. Not a permanent test — used to root-cause the spike.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { discoverFiles } from '../lib/walk.js';
import { analyzeRepo } from '../lib/analyze.js';

const FIX = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'demo');
console.log(`[diag] platform=${os.platform()} path.sep=${JSON.stringify(path.sep)}`);
const { files } = discoverFiles(FIX);
console.log('[diag] discovered rels:');
for (const f of files) console.log(`[diag]   rel=${JSON.stringify(f.rel)} lang=${f.lang}`);

const g = analyzeRepo(FIX);
console.log(`[diag] stats.files=${g.stats.files} brokenEdges=${g.stats.brokenEdges} (expected 2)`);
console.log('[diag] all links:');
for (const l of g.links) console.log(`[diag]   ${l.source} -> ${l.target} broken=${l.broken} kind=${l.kind}`);
console.log('[diag] phantom (missing) nodes:');
for (const n of g.nodes.filter((n) => n.missing)) console.log(`[diag]   ${n.id}`);
