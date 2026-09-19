#!/usr/bin/env node
// Circuit editor language server (CI-21): a zero-dependency stdio LSP server.
// It speaks the LSP JSON-RPC wire protocol by hand (Content-Length framing) so
// it needs no vscode-languageserver package — nothing but Node stdlib and
// Circuit's own real analyzer. On every open/save it re-grades the repo with the
// SAME lib/analyze.js the 3D app uses and publishes each file's findings as
// line-anchored diagnostics; the repo grade is pushed to the client status bar.
//
// Standalone:  node editor/server.mjs /path/to/repo   (stdin/stdout = LSP stream)
// It makes zero network calls — like the rest of Circuit, source never leaves
// the machine.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { analyzeRepo } from '../lib/analyze.js';
import { nodeToDiagnostics, repoStatus, nodeForRel } from './diagnostics.mjs';

// ---- JSON-RPC framing over a byte stream ----
function writeMessage(output, msg) {
  const body = Buffer.from(JSON.stringify(msg), 'utf8');
  output.write(`Content-Length: ${body.length}\r\n\r\n`);
  output.write(body);
}

// Parse a growing buffer into complete LSP messages, returning [messages, rest].
function drain(buffer) {
  const messages = [];
  while (true) {
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd === -1) break;
    const header = buffer.slice(0, headerEnd).toString('utf8');
    const m = header.match(/Content-Length:\s*(\d+)/i);
    if (!m) { buffer = buffer.slice(headerEnd + 4); continue; } // malformed header, skip
    const len = Number(m[1]);
    const start = headerEnd + 4;
    if (buffer.length < start + len) break; // body not fully arrived yet
    const body = buffer.slice(start, start + len).toString('utf8');
    buffer = buffer.slice(start + len);
    try { messages.push(JSON.parse(body)); } catch { /* drop unparseable frame */ }
  }
  return [messages, buffer];
}

function uriToPath(uri) {
  try { return fileURLToPath(uri); } catch { return uri.replace(/^file:\/\//, ''); }
}

// Repo-relative POSIX path for an absolute file path, or null if outside the repo.
function relFor(root, abs) {
  const rel = path.relative(root, abs);
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) return null;
  return rel.split(path.sep).join('/');
}

export function startLsp({ root, input = process.stdin, output = process.stdout } = {}) {
  let repoRoot = root ? path.resolve(root) : process.cwd();
  const log = (message, type = 3) =>
    writeMessage(output, { jsonrpc: '2.0', method: 'window/logMessage', params: { type, message } });

  // Re-grade the whole repo (real analyzeRepo) and publish diagnostics for one
  // file, plus the repo-grade status. Whole-repo scan is what gives cross-file
  // findings (broken wires, cycles) their honesty — the same as the live app.
  function regradeAndPublish(uri) {
    let graph;
    try {
      graph = analyzeRepo(repoRoot);
    } catch (e) {
      log(`Circuit analyze failed: ${e.message}`, 1);
      return;
    }
    // Status bar: repo grade (custom notification the client renders).
    writeMessage(output, { jsonrpc: '2.0', method: 'circuit/status', params: { text: repoStatus(graph) } });

    if (!uri) return;
    const abs = uriToPath(uri);
    const rel = relFor(repoRoot, abs);
    const node = rel ? nodeForRel(graph, rel) : null;
    writeMessage(output, {
      jsonrpc: '2.0',
      method: 'textDocument/publishDiagnostics',
      params: { uri, diagnostics: nodeToDiagnostics(node) },
    });
  }

  return new Promise((resolve) => {
    let buffer = Buffer.alloc(0);
    input.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      let messages;
      [messages, buffer] = drain(buffer);
      for (const msg of messages) handle(msg);
    });
    input.on('end', () => resolve());
    input.on('close', () => resolve());
    if (typeof input.resume === 'function') input.resume();

    function handle(msg) {
      const { id, method, params } = msg;
      switch (method) {
        case 'initialize': {
          // Prefer the client's declared workspace root.
          const wsUri = params?.workspaceFolders?.[0]?.uri ?? params?.rootUri;
          if (wsUri) repoRoot = path.resolve(uriToPath(wsUri));
          else if (params?.rootPath) repoRoot = path.resolve(params.rootPath);
          writeMessage(output, {
            jsonrpc: '2.0', id,
            result: {
              capabilities: {
                // openClose + save so the client streams the events we act on.
                textDocumentSync: { openClose: true, change: 0, save: { includeText: false } },
              },
              serverInfo: { name: 'circuit-lsp', version: '1' },
            },
          });
          return;
        }
        case 'initialized':
          regradeAndPublish(null); // seed the status bar with the repo grade
          return;
        case 'textDocument/didOpen':
          regradeAndPublish(params?.textDocument?.uri);
          return;
        case 'textDocument/didSave':
          regradeAndPublish(params?.textDocument?.uri);
          return;
        case 'textDocument/didClose':
          // Clear our squiggles for a closed file.
          writeMessage(output, {
            jsonrpc: '2.0', method: 'textDocument/publishDiagnostics',
            params: { uri: params?.textDocument?.uri, diagnostics: [] },
          });
          return;
        case 'shutdown':
          writeMessage(output, { jsonrpc: '2.0', id, result: null });
          return;
        case 'exit':
          resolve();
          return;
        default:
          // Respond to unknown requests (those with an id) so the client never hangs.
          if (id !== undefined) writeMessage(output, { jsonrpc: '2.0', id, result: null });
      }
    }
  });
}

// Run directly: `node editor/server.mjs [repoRoot]`.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = process.argv[2] ? path.resolve(process.argv[2]) : process.cwd();
  startLsp({ root }).then(() => process.exit(0));
}

export { pathToFileURL }; // re-export for the client/tests to build file URIs
