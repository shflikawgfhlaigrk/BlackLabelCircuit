// circuit-port — the portable helpers Circuit ships with a converted codebase.
// Converted JavaScript calls these instead of hard-coding macOS paths.
// Node standard library only.
import os from 'node:os';
import path from 'node:path';

const WIN = process.platform === 'win32';
const MAC = process.platform === 'darwin';

function base(macDir, winEnv, xdgEnv, xdgDefault) {
  if (MAC) return path.join(os.homedir(), 'Library', macDir);
  if (WIN) return process.env[winEnv] || path.join(os.homedir(), 'AppData', winEnv === 'LOCALAPPDATA' ? 'Local' : 'Roaming');
  return process.env[xdgEnv] || path.join(os.homedir(), ...xdgDefault);
}

// ~/Library/Application Support/<name> · %APPDATA%\<name> · $XDG_DATA_HOME/<name>
export function appSupport(...parts) {
  return path.join(base('Application Support', 'APPDATA', 'XDG_DATA_HOME', ['.local', 'share']), ...parts);
}

// ~/Library/Caches/<name> · %LOCALAPPDATA%\<name>\Cache · $XDG_CACHE_HOME/<name>
export function caches(...parts) {
  const root = base('Caches', 'LOCALAPPDATA', 'XDG_CACHE_HOME', ['.cache']);
  if (!WIN || parts.length === 0) return path.join(root, ...parts);
  return path.join(root, parts[0], 'Cache', ...parts.slice(1));
}

// ~/Library/Logs/<name> · %LOCALAPPDATA%\<name>\Logs · $XDG_STATE_HOME/<name>
export function logs(...parts) {
  const root = base('Logs', 'LOCALAPPDATA', 'XDG_STATE_HOME', ['.local', 'state']);
  if (!WIN || parts.length === 0) return path.join(root, ...parts);
  return path.join(root, parts[0], 'Logs', ...parts.slice(1));
}
