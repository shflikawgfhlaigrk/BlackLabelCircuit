// Local per-launch access. No public endpoint mints credentials.
import { randomBytes, timingSafeEqual } from 'node:crypto';

const token = () => randomBytes(32).toString('base64url');
function same(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export function createAccess({ ownerKey, now = Date.now, sessionMs = 3_600_000, handoffMs = 60_000 } = {}) {
  if (ownerKey !== undefined && !/^[A-Za-z0-9_-]{32,256}$/.test(ownerKey)) {
    throw new Error('CIRCUIT_OWNER_KEY must be an unpredictable 32–256 character key');
  }
  let handoff = token();
  let handoffExpiry = 0;
  const sessions = new Map();
  // Different instances use different cookie names even on the same hostname.
  const cookieName = `circuit_${token().slice(0, 16)}`;
  const prune = () => { for (const [id, expires] of sessions) if (expires <= now()) sessions.delete(id); };
  function principal(req) {
    const authorization = req.headers.authorization;
    if (authorization !== undefined) {
      return ownerKey && same(authorization, `Bearer ${ownerKey}`) ? { kind: 'owner' } : null;
    }
    prune();
    const cookies = String(req.headers.cookie ?? '').split(';').map(v => v.trim());
    const entries = cookies.filter(v => v.startsWith(`${cookieName}=`));
    if (entries.length !== 1) return null;
    const id = entries[0].slice(cookieName.length + 1);
    return sessions.has(id) ? { kind: 'session', id } : null;
  }
  function valid(p) {
    return p?.kind === 'owner' || (p?.kind === 'session' && (sessions.get(p.id) ?? 0) > now());
  }
  function exchange(value) {
    prune();
    if (!handoff || now() >= handoffExpiry || !same(value, handoff)) return null;
    handoff = null;
    const id = token();
    sessions.set(id, now() + sessionMs);
    return `${cookieName}=${id}; HttpOnly; SameSite=Strict; Path=/api/; Max-Age=${Math.floor(sessionMs / 1000)}`;
  }
  return {
    // Called only by the process startup channel, never by the HTTP router.
    launchURL(port) { handoffExpiry = now() + handoffMs; return `http://localhost:${port}/#handoff=${handoff}`; },
    principal, valid, exchange,
    logout(p) { if (p?.id) sessions.delete(p.id); },
    clearCookie: `${cookieName}=; HttpOnly; SameSite=Strict; Path=/api/; Max-Age=0`,
  };
}

export function requestBoundary(req, port) {
  const host = req.headers.host;
  if (host !== `localhost:${port}` && host !== `127.0.0.1:${port}`) return false;
  const origin = `http://${host}`;
  if (req.headers.origin !== undefined && req.headers.origin !== origin) return false;
  if (req.headers.referer !== undefined) {
    try { if (new URL(req.headers.referer).origin !== origin) return false; } catch { return false; }
  }
  const site = req.headers['sec-fetch-site'];
  return site === undefined || site === 'same-origin' || site === 'none';
}

export async function readMutation(req) {
  if (req.headers['x-circuit-request'] !== '1' ||
      !/^application\/json(?:\s*;.*)?$/i.test(req.headers['content-type'] ?? '')) {
    throw Object.assign(new Error('Use a Circuit JSON request'), { status: 415 });
  }
  if (Number(req.headers['content-length'] ?? 0) > 2048) throw Object.assign(new Error('Request too large'), { status: 413 });
  let bytes = 0;
  const chunks = [];
  req.setTimeout(5000, () => req.destroy());
  for await (const chunk of req) {
    bytes += chunk.length;
    if (bytes > 2048) throw Object.assign(new Error('Request too large'), { status: 413 });
    chunks.push(chunk);
  }
  const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (!body || Array.isArray(body) || typeof body !== 'object') throw new Error('Expected JSON object');
  return body;
}
