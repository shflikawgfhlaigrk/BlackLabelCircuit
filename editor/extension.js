// Circuit VS Code extension (CI-21): a thin, zero-third-party-dependency client
// for the stdio LSP server in this folder. It spawns editor/server.js, forwards
// open/save events, and renders what the server publishes — line-anchored
// diagnostics (the six-dimension review, per finding) into a DiagnosticCollection
// and the repo grade into a status-bar item. The only imports are the host-
// provided `vscode` API and Node builtins; no npm runtime dependency, no network.
const vscode = require('vscode');
const cp = require('node:child_process');
const path = require('node:path');
const { pathToFileURL, fileURLToPath } = require('node:url');

let child = null;
let buffer = Buffer.alloc(0);
let nextId = 1;

function send(msg) {
  if (!child) return;
  const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...msg }), 'utf8');
  child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  child.stdin.write(body);
}

function activate(context) {
  const folder = vscode.workspace.workspaceFolders?.[0];
  if (!folder) return; // nothing to grade without a workspace
  const root = folder.uri.fsPath;

  const diagnostics = vscode.languages.createDiagnosticCollection('circuit');
  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  status.text = 'Circuit: —';
  status.tooltip = 'Circuit repo grade — re-graded on every save';
  status.show();
  context.subscriptions.push(diagnostics, status);

  const serverPath = path.join(__dirname, 'server.mjs');
  // Spawn the Code binary as Node (the standard extension-host trick), so the
  // server runs on the same runtime with no external `node` requirement.
  child = cp.spawn(process.execPath, [serverPath, root], {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  child.stdout.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      const headerEnd = buffer.indexOf('\r\n\r\n');
      if (headerEnd === -1) break;
      const m = buffer.slice(0, headerEnd).toString('utf8').match(/Content-Length:\s*(\d+)/i);
      if (!m) { buffer = buffer.slice(headerEnd + 4); continue; }
      const len = Number(m[1]);
      const start = headerEnd + 4;
      if (buffer.length < start + len) break;
      let msg;
      try { msg = JSON.parse(buffer.slice(start, start + len).toString('utf8')); } catch { msg = null; }
      buffer = buffer.slice(start + len);
      if (msg) onMessage(msg, diagnostics, status);
    }
  });
  child.on('exit', () => { child = null; });
  context.subscriptions.push({ dispose: () => child?.kill() });

  send({ id: nextId++, method: 'initialize', params: { rootUri: folder.uri.toString(), workspaceFolders: [{ uri: folder.uri.toString(), name: folder.name }] } });
  send({ method: 'initialized', params: {} });

  const notify = (doc, method) => {
    if (doc.uri.scheme !== 'file') return;
    send({ method, params: { textDocument: { uri: pathToFileURL(doc.uri.fsPath).href } } });
  };
  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((doc) => notify(doc, 'textDocument/didSave')),
    vscode.workspace.onDidOpenTextDocument((doc) => notify(doc, 'textDocument/didOpen')),
  );
  if (vscode.window.activeTextEditor) notify(vscode.window.activeTextEditor.document, 'textDocument/didOpen');
}

function onMessage(msg, diagnostics, status) {
  if (msg.method === 'circuit/status') {
    status.text = msg.params?.text ?? 'Circuit: —';
    return;
  }
  if (msg.method === 'textDocument/publishDiagnostics') {
    const { uri, diagnostics: list = [] } = msg.params ?? {};
    const target = vscode.Uri.file(fileURLToPath(uri));
    diagnostics.set(target, list.map((d) => {
      const r = d.range;
      const range = new vscode.Range(r.start.line, r.start.character, r.end.line, Math.min(r.end.character, 100000));
      const diag = new vscode.Diagnostic(range, d.message, (d.severity ?? 3) - 1); // LSP 1..4 → VS Code 0..3
      diag.source = 'circuit';
      diag.code = d.code;
      return diag;
    }));
  }
}

function deactivate() { child?.kill(); child = null; }

module.exports = { activate, deactivate };
