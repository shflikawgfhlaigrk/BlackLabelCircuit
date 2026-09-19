// File discovery: prefer `git ls-files` (respects .gitignore), fall back to fs walk.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const IGNORE_DIRS = new Set([
  'node_modules', '.git', '.svn', '.hg', 'dist', 'build', '.build', 'out',
  'DerivedData', 'Pods', 'Carthage', '.next', '.nuxt', '.output', 'coverage',
  'venv', '.venv', 'env', '__pycache__', '.pytest_cache', '.mypy_cache',
  '.tox', 'target', 'vendor', '.idea', '.vscode', '.cache', 'tmp', '.tmp',
  '.wrangler', '.swiftpm', 'xcuserdata', '.dart_tool',
]);

export const LANG_BY_EXT = {
  '.js': 'javascript', '.mjs': 'javascript', '.cjs': 'javascript', '.jsx': 'javascript',
  '.ts': 'typescript', '.tsx': 'typescript', '.mts': 'typescript', '.cts': 'typescript',
  '.py': 'python',
  '.swift': 'swift',
  '.go': 'go', '.rs': 'rust', '.java': 'java', '.kt': 'kotlin', '.rb': 'ruby',
  '.c': 'c', '.h': 'c', '.cpp': 'cpp', '.hpp': 'cpp', '.cc': 'cpp', '.m': 'objc', '.mm': 'objc',
  '.sh': 'shell', '.zsh': 'shell', '.bash': 'shell',
  '.css': 'css', '.scss': 'css',
  '.html': 'html', '.vue': 'vue', '.svelte': 'svelte',
  '.json': 'json', '.yaml': 'yaml', '.yml': 'yaml', '.toml': 'toml',
};

const MAX_FILE_BYTES = 1_500_000;
const MAX_FILES = 4000;

const LOCKFILES = new Set(['package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'Cargo.lock', 'Podfile.lock', 'Gemfile.lock', 'composer.lock']);

function isMinified(relPath) {
  return /\.min\.(js|css)$/.test(relPath) || /\.(bundle|pack)\.js$/.test(relPath);
}

function gitListFiles(root) {
  try {
    const out = execFileSync('git', ['-C', root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], {
      maxBuffer: 64 * 1024 * 1024, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    });
    return out.split('\0').filter(Boolean);
  } catch {
    return null;
  }
}

function fsWalk(root) {
  const files = [];
  const stack = [''];
  while (stack.length) {
    const rel = stack.pop();
    const abs = path.join(root, rel);
    let entries;
    try { entries = fs.readdirSync(abs, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      if (e.name.startsWith('.') && e.name !== '.') continue;
      // Always join with a forward slash so rels are POSIX on every OS —
      // path.join would use `\` on Windows and desync from git ls-files.
      const childRel = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) {
        if (!IGNORE_DIRS.has(e.name)) stack.push(childRel);
      } else if (e.isFile()) {
        files.push(childRel);
      }
    }
  }
  return files;
}

// Returns { files: [{rel, abs, lang, bytes}], truncated }
export function discoverFiles(root) {
  // An empty git listing is not proof of an empty folder: a directory nested in a
  // parent repo that ignores it (a scratch worktree under a home-directory repo,
  // say) lists nothing through git. Fall back to walking the disk in that case.
  let rels = gitListFiles(root);
  if (!rels || rels.length === 0) rels = fsWalk(root);
  // Normalize to POSIX separators regardless of source (git ls-files is already
  // POSIX; fsWalk now is too — this guards any future path source on Windows).
  rels = rels.map((rel) => rel.split('\\').join('/'));
  // git ls-files may include ignored-dir names if committed; filter regardless
  rels = rels.filter((rel) => {
    const parts = rel.split('/');
    if (parts.some((p) => IGNORE_DIRS.has(p))) return false;
    if (LOCKFILES.has(parts[parts.length - 1])) return false;
    if (isMinified(rel)) return false;
    const ext = path.extname(rel).toLowerCase();
    return ext in LANG_BY_EXT;
  });
  rels.sort();
  const truncated = rels.length > MAX_FILES;
  if (truncated) rels = rels.slice(0, MAX_FILES);

  const files = [];
  for (const rel of rels) {
    const abs = path.join(root, rel);
    let st;
    try { st = fs.statSync(abs); } catch { continue; }
    if (!st.isFile() || st.size > MAX_FILE_BYTES) continue;
    files.push({ rel, abs, lang: LANG_BY_EXT[path.extname(rel).toLowerCase()], bytes: st.size });
  }
  return { files, truncated };
}

// Churn: commits touching each file in the last 90 days. Empty map when not a git repo.
export function gitChurn(root) {
  const churn = new Map();
  try {
    const out = execFileSync('git', ['-C', root, 'log', '--since=90 days ago', '--name-only', '--pretty=format:'], {
      maxBuffer: 64 * 1024 * 1024, encoding: 'utf8',
    });
    for (const line of out.split('\n')) {
      const rel = line.trim();
      if (rel) churn.set(rel, (churn.get(rel) ?? 0) + 1);
    }
  } catch { /* not a git repo */ }
  return churn;
}
