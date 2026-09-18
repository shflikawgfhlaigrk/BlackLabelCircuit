// Black Label Marketing — buyer-owned Cloudflare newsletter delivery.
//
// The app sends bounded chunks (maximum 100) with one stable deliveryID. A Durable Object owns the
// per-recipient receipt ledger for that delivery, so retries skip already accepted recipients. The
// Worker never truncates: an oversized request is rejected before EMAIL.send is called.

export const MAX_RECIPIENTS = 100;
export const PROTOCOL_VERSION = 2;

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

async function timingSafeEqualStr(a, b) {
  const enc = new TextEncoder();
  const [da, db] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const va = new Uint8Array(da), vb = new Uint8Array(db);
  let diff = 0;
  for (let i = 0; i < va.length; i++) diff |= va[i] ^ vb[i];
  return diff === 0;
}

function normalizedRecipient(value) {
  return String(value ?? "").trim().toLowerCase();
}

function validateBody(body) {
  const from = String(body?.from ?? "").trim();
  const fromName = String(body?.fromName ?? "").trim();
  const subject = String(body?.subject ?? "").trim();
  const text = String(body?.text ?? "");
  const html = String(body?.html ?? "");
  const deliveryID = String(body?.deliveryID ?? "").trim();
  const protocolVersion = Number(body?.protocolVersion ?? 0);
  const recipients = Array.isArray(body?.recipients)
    ? body.recipients.map(normalizedRecipient)
    : [];

  if (!from || !subject || recipients.length === 0)
    return { error: "from, subject, and recipients are required", status: 400 };
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(from))
    return { error: "from must be a valid email address", status: 400 };
  if (!html && !text)
    return { error: "a text or html body is required", status: 400 };
  if (!/^[A-Za-z0-9._:-]{1,128}$/.test(deliveryID))
    return { error: "a valid deliveryID is required", status: 400 };
  if (protocolVersion !== PROTOCOL_VERSION)
    return { error: `newsletter protocol ${PROTOCOL_VERSION} is required`, status: 426 };
  if (recipients.length > MAX_RECIPIENTS)
    return { error: `recipient chunk exceeds ${MAX_RECIPIENTS}; nothing was sent`, status: 413 };
  if (recipients.some((email) => !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)))
    return { error: "every recipient must be a valid email address", status: 400 };
  if (new Set(recipients).size !== recipients.length)
    return { error: "recipient chunk contains duplicates", status: 400 };

  return { value: { from, fromName, subject, text, html, deliveryID, protocolVersion, recipients } };
}

async function recipientStorageKey(email) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(email));
  return `recipient:${Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("")}`;
}

/// One instance exists per deliveryID. Storage contains only hashed recipient keys and status — the
/// Worker never persists the buyer's mailing list or message content.
export class NewsletterProgress {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    let raw;
    try { raw = await request.json(); }
    catch { return json({ ok: false, error: "invalid JSON", results: [] }, 400); }
    const checked = validateBody(raw);
    if (checked.error)
      return json({ ok: false, error: checked.error, sent: 0, failed: raw?.recipients?.length ?? 0, truncated: false, results: [] }, checked.status);

    const body = checked.value;
    const results = [];
    let delivered = 0, deduplicated = 0;

    for (const recipient of body.recipients) {
      const key = await recipientStorageKey(recipient);
      const existing = await this.state.storage.get(key);
      if (existing?.status === "sent") {
        deduplicated++;
        results.push({ recipient, state: "sent", detail: "Already accepted on an earlier attempt", idempotent: true });
        continue;
      }
      if (existing?.status === "sending") {
        // The previous invocation stopped between provider submission and durable confirmation.
        // Retrying could duplicate a real message, so hold this recipient for manual reconciliation.
        results.push({ recipient, state: "failed", detail: "Prior provider attempt is unconfirmed; held to prevent a duplicate", idempotent: true });
        continue;
      }

      await this.state.storage.put(key, { status: "sending", at: Date.now() });
      try {
        await this.env.EMAIL.send({
          to: recipient,
          from: { email: body.from, name: body.fromName || body.from },
          subject: body.subject,
          text: body.text || undefined,
          html: body.html || undefined,
        });
      } catch (error) {
        // A provider rejection is safe to retry. Delete the provisional marker only when the send
        // call itself returned a failure.
        await this.state.storage.delete(key);
        results.push({
          recipient,
          state: "failed",
          detail: error && error.message ? error.message : String(error),
          idempotent: false,
        });
        continue;
      }
      try {
        await this.state.storage.put(key, { status: "sent", at: Date.now() });
        delivered++;
        results.push({ recipient, state: "sent", detail: "Provider accepted", idempotent: false });
      } catch (error) {
        // The provider accepted but durable confirmation failed. Keep the `sending` marker and
        // report an honest hold; deleting it would allow a retry to duplicate the real message.
        results.push({
          recipient,
          state: "failed",
          detail: "Provider accepted, but durable confirmation failed; held to prevent a duplicate",
          idempotent: true,
        });
      }
    }

    const sent = results.filter((result) => result.state === "sent").length;
    const failed = results.length - sent;
    const ok = failed === 0 && sent === body.recipients.length;
    const errors = results.filter((result) => result.state === "failed").slice(0, 5)
      .map((result) => `${result.recipient}: ${result.detail}`);
    const status = ok ? 200 : (sent > 0 ? 207 : 502);
    return json({
      ok, protocolVersion: PROTOCOL_VERSION, sent, delivered, deduplicated,
      failed, errors, truncated: false, results,
    }, status);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    const auth = request.headers.get("authorization") || "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!env.SEND_SECRET || !(await timingSafeEqualStr(token, env.SEND_SECRET)))
      return json({ ok: false, error: "unauthorized" }, 401);

    if (request.method === "GET" && url.pathname === "/capabilities") {
      return json({
        ok: true,
        protocolVersion: PROTOCOL_VERSION,
        durableProgress: Boolean(env.NEWSLETTER_PROGRESS),
        maxRecipientsPerRequest: MAX_RECIPIENTS,
      });
    }
    if (request.method !== "POST") return json({ ok: false, error: "POST only" }, 405);
    if (url.pathname !== "/send") return json({ ok: false, error: "not found" }, 404);

    let raw;
    try { raw = await request.json(); }
    catch { return json({ ok: false, error: "invalid JSON" }, 400); }
    const checked = validateBody(raw);
    if (checked.error) {
      return json({
        ok: false, error: checked.error, sent: 0,
        failed: Array.isArray(raw?.recipients) ? raw.recipients.length : 0,
        truncated: false, results: [],
      }, checked.status);
    }
    if (!env.NEWSLETTER_PROGRESS) {
      return json({ ok: false, error: "durable progress binding is not configured", sent: 0,
                    failed: checked.value.recipients.length, truncated: false, results: [] }, 503);
    }

    const id = env.NEWSLETTER_PROGRESS.idFromName(checked.value.deliveryID);
    const stub = env.NEWSLETTER_PROGRESS.get(id);
    return stub.fetch(new Request("https://newsletter-progress.internal/send", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(checked.value),
    }));
  },
};
