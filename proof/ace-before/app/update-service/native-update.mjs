// Native update delivery uses the same fresh, device-bound licence authority
// as activation. Browser cookies and private purchase receipt URLs are never
// required or exported to the app. The caller supplies the release already
// selected by the canonical release-channel Worker, not a request-chosen key.

const activationURL = 'https://ace-bl.tech/api/ace/activate';
const productionKeys = Object.freeze({
  'ace-ed25519-prod20260813a': new Uint8Array([
    0x33, 0xf8, 0xf9, 0xdd, 0xdc, 0x95, 0xb0, 0xf4,
    0x98, 0xe9, 0xab, 0x4d, 0x32, 0x2a, 0x9d, 0x16,
    0xfe, 0x53, 0x54, 0x92, 0x9c, 0xa1, 0x08, 0xb1,
    0x29, 0x92, 0x47, 0x75, 0xaf, 0x76, 0xc3, 0x84,
  ]),
});
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
const claimKeys = ['brainRoute', 'deviceId', 'expiresAt', 'issuedAt',
  'keyHash', 'nonce', 'schemaVersion'];

function json(error, status) {
  return Response.json({ ok: false, error }, { status, headers: {
    'cache-control': 'private, no-store',
    'referrer-policy': 'no-referrer',
    'x-content-type-options': 'nosniff',
    ...(status === 405 ? { allow: 'POST' } : {}),
  } });
}

async function boundedJSON(message, maximum) {
  if (!message.headers.get('content-type')?.toLowerCase().startsWith('application/json')) {
    throw new Error('invalid_content_type');
  }
  const length = message.headers.get('content-length');
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > maximum)) {
    throw new Error('body_too_large');
  }
  if (!message.body) throw new Error('empty_body');
  const reader = message.body.getReader();
  const pieces = [];
  let total = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maximum) throw new Error('body_too_large');
      pieces.push(value);
    }
  } catch (error) {
    await reader.cancel().catch(() => {});
    throw error;
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const piece of pieces) { bytes.set(piece, offset); offset += piece.length; }
  return JSON.parse(decoder.decode(bytes));
}

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function decodeBase64url(value, maximum) {
  if (typeof value !== 'string' || value.length > maximum || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error('invalid_encoding');
  }
  const bytes = Uint8Array.from(atob(value.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
  if (base64url(bytes) !== value) throw new Error('noncanonical_encoding');
  return bytes;
}

export async function verifyUpdateLease(response, { key, deviceId, now, publicKeys = productionKeys }) {
  try {
    if (response?.ok !== true) return false;
    const rawKey = publicKeys[response.leaseKeyId];
    if (!(rawKey instanceof Uint8Array) || rawKey.length !== 32) return false;
    const payload = decodeBase64url(response.leasePayload, 4096);
    const signature = decodeBase64url(response.leaseSignature, 128);
    if (signature.length !== 64) return false;
    const verificationKey = await crypto.subtle.importKey('raw', rawKey, 'Ed25519', false, ['verify']);
    if (!await crypto.subtle.verify('Ed25519', verificationKey, signature, payload)) return false;
    const claims = JSON.parse(decoder.decode(payload));
    if (JSON.stringify(Object.keys(claims).sort()) !== JSON.stringify(claimKeys)) return false;
    const keyHash = base64url(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(key))));
    return claims.schemaVersion === 1
      && claims.keyHash === keyHash && claims.deviceId === deviceId
      && ['customer_owned', 'founder_hosted'].includes(claims.brainRoute)
      && response.brainRoute === claims.brainRoute
      && Number.isSafeInteger(claims.issuedAt) && Number.isSafeInteger(claims.expiresAt)
      && Number.isSafeInteger(now)
      && claims.issuedAt <= now + 300_000
      && claims.expiresAt >= now + 300_000
      && claims.expiresAt > claims.issuedAt
      && claims.expiresAt - claims.issuedAt <= 7 * 24 * 60 * 60 * 1000
      && response.expiresAt === claims.expiresAt
      && typeof claims.nonce === 'string' && claims.nonce.length >= 16;
  } catch { return false; }
}

function releaseIsValid(release) {
  return release?.version && Number.isSafeInteger(release.build) && release.build > 0
    && /^[0-9a-f]{64}$/.test(release.sourceSha256)
    && /^[0-9a-f]{64}$/.test(release.dmgSha256)
    && Number.isSafeInteger(release.dmgBytes) && release.dmgBytes > 0;
}

export function createNativeUpdateHandler({
  currentRelease, deliver, fetchActivation = fetch, now = Date.now,
  publicKeys = productionKeys,
}) {
  return async function nativeUpdate(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/api/ace/update') return null;
    if (url.protocol !== 'https:' || !['ace-bl.tech', 'www.ace-bl.tech'].includes(url.hostname)) {
      return json('not_found', 404);
    }
    if (request.method !== 'POST') return json('method_not_allowed', 405);
    let body;
    try { body = await boundedJSON(request, 4096); }
    catch { return json('invalid_request', 400); }
    if (!body || Array.isArray(body)
        || Object.keys(body).sort().join(',') !== 'build,deviceId,deviceName,dmgSha256,key,sourceSha256'
        || !/^ACE-(?:[A-Z0-9]{4}-){3}[A-Z0-9]{4}$/.test(body.key)
        || typeof body.deviceId !== 'string' || body.deviceId.length < 1 || body.deviceId.length > 200
        || /[\x00-\x1f\x7f]/.test(body.deviceId)
        || typeof body.deviceName !== 'string' || body.deviceName.length > 200) {
      return json('invalid_request', 400);
    }
    let release;
    try { release = currentRelease(env); }
    catch { return json('release_unavailable', 503); }
    if (!releaseIsValid(release)) return json('release_unavailable', 503);
    if (body.build !== release.build || body.sourceSha256 !== release.sourceSha256
        || body.dmgSha256 !== release.dmgSha256) return json('release_changed', 409);

    // No cookies, redirect following, buyer receipt, or caller-selected host.
    // This also rechecks cancellation/revocation with the live licence service.
    let response;
    try {
      response = await fetchActivation(new Request(activationURL, {
        method: 'POST', redirect: 'manual',
        headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
        body: JSON.stringify({ key: body.key, deviceId: body.deviceId, deviceName: body.deviceName }),
        signal: AbortSignal.timeout(15_000),
      }));
    } catch { return json('licence_unavailable', 503); }
    if (response.status !== 200) {
      await response.body?.cancel().catch(() => {});
      return json([400, 401, 403, 409, 422].includes(response.status)
        ? 'licence_refused' : 'licence_unavailable',
      [400, 401, 403, 409, 422].includes(response.status) ? 403 : 503);
    }
    let lease;
    try { lease = await boundedJSON(response, 8192); }
    catch { return json('licence_unavailable', 503); }
    if (!await verifyUpdateLease(lease, {
      key: body.key, deviceId: body.deviceId, now: now(), publicKeys,
    })) return json('licence_unavailable', 503);
    try {
      // Delivery must use the existing immutable-object/digest/ETag guard.
      // No Range header is carried across a new update transaction.
      const result = await deliver(release, env);
      if (result.status !== 200) return json('download_unavailable', 503);
      const headers = new Headers(result.headers);
      headers.set('cache-control', 'private, no-store');
      headers.set('referrer-policy', 'no-referrer');
      headers.set('x-ace-source-sha256', release.sourceSha256);
      headers.set('x-ace-dmg-sha256', release.dmgSha256);
      return new Response(result.body, { status: 200, headers });
    } catch { return json('download_unavailable', 503); }
  };
}
