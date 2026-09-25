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

export const MAX_FILE_BYTES = 1_500_000;
const MAX_FILES = 4000;

const LOCKFILES = new Set(['package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'Cargo.lock', 'Podfile.lock', 'Gemfile.lock', 'composer.lock']);

function isMinified(relPath) {
  return /\.min\.(js|css)$/.test(relPath) || /\.(bundle|pack)\.js$/.test(relPath);
}

function isWithinRoot(rootReal, candidateReal) {
  const relative = path.relative(rootReal, candidateReal);
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith('..' + path.sep) &&
    !path.isAbsolute(relative)
  );
}

// Resolve both the link-free metadata and the canonical target. lstat alone
// does not catch an ancestor directory being replaced with an outside link.
function inspectPath(root, rootReal, rel) {
  const abs = path.resolve(root, rel);
  try {
    const stat = fs.lstatSync(abs);
    const realPath = fs.realpathSync(abs);
    return { abs, realPath, stat, outside: !isWithinRoot(rootReal, realPath) };
  } catch {
    return null;
  }
}

function gitListFiles(root) {
  try {
    const out = execFileSync('git', ['-C', root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], {
      maxBuffer: 64 * 1024 * 1024, encoding: 'utf8',
    });
    return out.split('\0').filter(Boolean);
  } catch {
    return null;
  }
}

function fsWalk(root, rootReal) {
  const files = [];
  let skipped = 0;
  const stack = [''];
  while (stack.length) {
    const rel = stack.pop();
    const abs = path.join(root, rel);
    if (rel) {
      const directory = inspectPath(root, rootReal, rel);
      if (!directory || directory.outside || directory.stat.isSymbolicLink() || !directory.stat.isDirectory()) {
        skipped++;
        continue;
      }
    }
    let entries;
    try { entries = fs.readdirSync(abs, { withFileTypes: true }); } catch {
      skipped++;
      continue;
    }
    for (const e of entries) {
      if (e.name.startsWith('.') && e.name !== '.') continue;
      // Always join with a forward slash so rels are POSIX on every OS —
      // path.join would use `\` on Windows and desync from git ls-files.
      const childRel = rel ? `${rel}/${e.name}` : e.name;
      // Never follow project symlinks: they may escape root or create cycles.
      // Count them so discovery never presents partial coverage as complete.
      const candidate = inspectPath(root, rootReal, childRel);
      if (!candidate || candidate.outside || candidate.stat.isSymbolicLink()) {
        skipped++;
        continue;
      }
      if (candidate.stat.isDirectory()) {
        if (!IGNORE_DIRS.has(e.name)) stack.push(childRel);
      } else if (candidate.stat.isFile()) {
        files.push({
          rel: childRel,
          abs: candidate.abs,
          realPath: candidate.realPath,
          dev: candidate.stat.dev,
          ino: candidate.stat.ino,
          bytes: candidate.stat.size,
        });
      } else {
        skipped++;
      }
    }
  }
  return { files, skipped };
}

// Returns { files: [{rel, abs, realPath, dev, ino, lang, bytes}], truncated, skipped }
export function discoverFiles(root) {
  let rootReal;
  try { rootReal = fs.realpathSync(root); } catch { return { files: [], truncated: false, skipped: 1 }; }
  try {
    if (!fs.statSync(rootReal).isDirectory()) return { files: [], truncated: false, skipped: 1 };
  } catch {
    return { files: [], truncated: false, skipped: 1 };
  }
  let skipped = 0;
  let rels = gitListFiles(root);
  if (rels === null) {
    const walked = fsWalk(root, rootReal);
    rels = walked.files;
    skipped = walked.skipped;
  } else {
    rels = rels.filter((rel) => {
      const candidate = inspectPath(root, rootReal, rel);
      if (!candidate || candidate.outside || candidate.stat.isSymbolicLink()) {
        skipped++;
        return false;
      }
      return true;
    });
  }
  // Normalize to POSIX separators regardless of source (git ls-files is already
  // POSIX; fsWalk now is too — this guards any future path source on Windows).
  rels = rels.map((entry) => typeof entry === 'string'
    ? { rel: entry.split('\\').join('/') }
    : { ...entry, rel: entry.rel.split('\\').join('/') });
  // git ls-files may include ignored-dir names if committed; filter regardless
  rels = rels.filter(({ rel }) => {
    const parts = rel.split('/');
    if (parts.some((p) => IGNORE_DIRS.has(p))) return false;
    if (LOCKFILES.has(parts[parts.length - 1])) return false;
    if (isMinified(rel)) return false;
    const ext = path.extname(rel).toLowerCase();
    return ext in LANG_BY_EXT;
  });
  rels.sort((a, b) => a.rel.localeCompare(b.rel));
  const truncated = rels.length > MAX_FILES;
  if (truncated) rels = rels.slice(0, MAX_FILES);

  const files = [];
  for (const entry of rels) {
    // Recheck after filtering: the path may have changed since the first
    // containment check, including an ancestor becoming a symlink.
    const candidate = inspectPath(root, rootReal, entry.rel);
    if (!candidate || candidate.outside || candidate.stat.isSymbolicLink()) {
      skipped++;
      continue;
    }
    if (!candidate.stat.isFile() || candidate.stat.size > MAX_FILE_BYTES) {
      skipped++;
      continue;
    }
    files.push({
      rel: entry.rel,
      abs: candidate.abs,
      realPath: candidate.realPath,
      dev: candidate.stat.dev,
      ino: candidate.stat.ino,
      lang: LANG_BY_EXT[path.extname(entry.rel).toLowerCase()],
      bytes: candidate.stat.size,
    });
  }
  return { files, truncated, skipped };
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
