// Resolve the original purchase using the licence already held by this Mac.
// This endpoint reads existing records only. It neither grants entitlement nor
// provisions purchases, sends mail, updates billing, or stores receipt URLs.
const route = '/api/007/ace/recovery';
const headers = {
  'cache-control': 'private, no-store',
  'referrer-policy': 'no-referrer',
  'x-content-type-options': 'nosniff',
  'x-robots-tag': 'noindex, nofollow',
};
const reply = (body, status = 200) => Response.json(body, {status, headers});
const refusal = () => reply({ok: false, error: 'purchase_not_verified'}, 403);

async function boundedRequest(request) {
  if (request.headers.get('content-type')?.split(';')[0].trim() !== 'application/json') throw new Error();
  const reader = request.body?.getReader();
  if (!reader) throw new Error();
  const chunks = []; let length = 0;
  try {
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      length += value.length;
      if (length > 2048) throw new Error();
      chunks.push(value);
    }
  } catch (error) {
    await reader.cancel().catch(() => {}); throw error;
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes));
}

export async function handlePurchaseRecovery(request, env) {
  const requestURL = new URL(request.url);
  if (requestURL.pathname !== route) return null;
  if (requestURL.origin !== 'https://blacklabelbots.com' || requestURL.search) return reply({ok:false, error:'invalid_request'}, 400);
  if (request.method !== 'POST') return reply({ok:false, error:'method_not_allowed'}, 405);
  let body;
  try { body = await boundedRequest(request); } catch { return reply({ok:false, error:'invalid_request'}, 400); }
  if (!body || Array.isArray(body) || Object.keys(body).sort().join(',') !== 'action,deviceId,key'
      || !['account', 'billing', 'support'].includes(body.action)
      || typeof body.key !== 'string' || !/^ACE-(?:[A-Z0-9]{4}-){3}[A-Z0-9]{4}$/.test(body.key)
      || typeof body.deviceId !== 'string' || body.deviceId.length < 1 || body.deviceId.length > 200
      || /[\s\x00-\x1f\x7f]/.test(body.deviceId)) return reply({ok:false, error:'invalid_request'}, 400);
  try {
    const record = await env.ACE_SUBSCRIBERS.get(`license:${body.key}`, 'json');
    if (!record || record.key !== body.key || record.deviceId !== body.deviceId
        || typeof record.email !== 'string' || !record.subscription || !record.customer) return refusal();
    const account = await env.ACE_SUBSCRIBERS.get(`acct:${record.email}`, 'json');
    if (!account || !((account.key === body.key && account.subscription === record.subscription)
        || account.sales?.some(sale => sale.key === body.key && sale.subscription === record.subscription))) return refusal();

    if (record.offer === 'dollar-week-launch-20260813') {
      return reply({ok: true, channel: 'ace', url: 'https://ace-bl.tech/account'});
    }
    const complimentary = record.offer === 'ace-complimentary-007-customer-20260915';
    if (!complimentary && record.offer !== 'ace-75-20260915') return refusal();
    if (!/^cs_live_[A-Za-z0-9_]{8,240}$/.test(record.checkout || '')) return refusal();
    // The sale journal independently binds checkout, buyer, subscription and
    // key. A half-written or mismatched KV projection cannot reveal a receipt.
    const row = await env.LICENSE_DB.prepare('SELECT record_json FROM ace_delivery_sales WHERE subscription_id = ?')
      .bind(record.subscription).first();
    const sale = row && JSON.parse(row.record_json);
    if (!sale || ['key', 'email', 'customer', 'subscription', 'checkout', 'offer']
      .some(field => sale[field] !== record[field])) return refusal();
    if (complimentary && record.checkout !== env.ACE_COMPLIMENTARY_007_CHECKOUT) return refusal();
    if (!/^\/r\/[A-Za-z0-9_-]{32,80}$/.test(env.SEVEN_RECEIPT_PATH || '')) {
      return reply({ok:false, error:'recovery_unavailable'}, 503);
    }
    // Complimentary Ace has no separate Ace subscription to cancel.
    if (complimentary && body.action === 'billing') {
      return reply({ok:false, error:'no_ace_subscription'}, 409);
    }
    const suffix = complimentary ? '/ace' : body.action === 'billing' ? '/manage' : '';
    const destination = new URL(env.SEVEN_RECEIPT_PATH + suffix, 'https://blacklabelbots.com');
    destination.searchParams.set('session_id', record.checkout);
    return reply({ok:true, channel:'blacklabelbots', url:destination.href});
  } catch {
    return reply({ok:false, error:'recovery_unavailable'}, 503);
  }
}
