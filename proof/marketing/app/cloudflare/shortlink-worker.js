// Black Label Marketing — buyer-owned branded short links (Cloudflare Workers + KV, free tier).
//
// This Worker runs on the BUYER'S OWN Cloudflare account — the app deploys it one-click from
// Distribute → Short Links (Sources/Shortlinks.swift uploads this exact script over the Cloudflare
// API), or you can deploy it manually with wrangler. Bindings it expects:
//   LINKS         KV namespace  (link:<slug> → destination URL; clicks:<slug> → counter)
//   ADMIN_SECRET  bearer secret for the /api/* management routes (the app generates + stores it)
//
// Routes:
//   GET  /<slug>              → 301 redirect to the stored destination (public)
//   GET  /api/health          → { ok, service, version }                    (bearer)
//   GET  /api/links           → { ok, links: [{slug,url,created,clicks}] }  (bearer)
//   POST /api/links           → create { slug, url }                        (bearer)
//   DELETE /api/links/<slug>  → delete the link + its counter               (bearer)
//
// HONEST LIMITS: click counters use KV read-modify-write — KV has no atomic increment, so
// concurrent clicks can under-count. Redirects are 301 and may be cached by browsers/CDNs.
// The app surfaces both caveats; never present these counts as exact analytics.

export const VERSION = 1;
const SLUG_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/;

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

function normalizeSlug(value) {
  return String(value ?? "").trim().toLowerCase();
}

// Only absolute http(s) destinations — a short link must never 301 into javascript:/data:.
function validDestination(raw) {
  let url;
  try { url = new URL(String(raw ?? "").trim()); } catch { return null; }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  return url.toString();
}

async function authorized(request, env) {
  const auth = request.headers.get("authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  return Boolean(env.ADMIN_SECRET) && (await timingSafeEqualStr(token, env.ADMIN_SECRET));
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // ---- management API (bearer = the buyer's own admin secret) ----
    if (path === "/api/health" || path === "/api/links" || path.startsWith("/api/links/")) {
      if (!(await authorized(request, env))) return json({ ok: false, error: "unauthorized" }, 401);
      if (!env.LINKS) return json({ ok: false, error: "LINKS KV binding is not configured" }, 503);

      if (path === "/api/health" && request.method === "GET") {
        return json({ ok: true, service: "shortlinks", version: VERSION });
      }

      if (path === "/api/links" && request.method === "GET") {
        const links = [];
        let cursor;
        do {
          const page = await env.LINKS.list({ prefix: "link:", cursor });
          for (const key of page.keys) {
            links.push({
              slug: key.name.slice("link:".length),
              url: (key.metadata && key.metadata.url) || "",
              created: (key.metadata && key.metadata.created) || "",
              clicks: 0,
            });
          }
          cursor = page.list_complete ? undefined : page.cursor;
        } while (cursor);
        for (const link of links) {
          if (!link.url) link.url = (await env.LINKS.get("link:" + link.slug)) || "";
          const clicks = await env.LINKS.get("clicks:" + link.slug);
          link.clicks = clicks ? Number(clicks) || 0 : 0;
        }
        links.sort((a, b) => (b.created || "").localeCompare(a.created || ""));
        return json({ ok: true, version: VERSION, links });
      }

      if (path === "/api/links" && request.method === "POST") {
        let body;
        try { body = await request.json(); }
        catch { return json({ ok: false, error: "invalid JSON" }, 400); }
        const slug = normalizeSlug(body && body.slug);
        const destination = validDestination(body && body.url);
        if (!SLUG_RE.test(slug) || slug === "api") {
          return json({ ok: false, error: "slug must be 1-64 chars of a-z, 0-9, - or _ (and not 'api')" }, 400);
        }
        if (!destination) return json({ ok: false, error: "url must be a valid http(s) URL" }, 400);
        if (await env.LINKS.get("link:" + slug)) {
          return json({ ok: false, error: "that slug already exists — delete it first or pick another" }, 409);
        }
        const created = new Date().toISOString();
        await env.LINKS.put("link:" + slug, destination, { metadata: { url: destination, created } });
        return json({ ok: true, link: { slug, url: destination, created, clicks: 0 } }, 201);
      }

      const match = path.match(/^\/api\/links\/([^/]+)$/);
      if (match && request.method === "DELETE") {
        const slug = normalizeSlug(decodeURIComponent(match[1]));
        if (!SLUG_RE.test(slug)) return json({ ok: false, error: "invalid slug" }, 400);
        await env.LINKS.delete("link:" + slug);
        await env.LINKS.delete("clicks:" + slug);
        return json({ ok: true, deleted: slug });
      }

      return json({ ok: false, error: "not found" }, 404);
    }

    // ---- public redirect: GET /<slug> → 301 ----
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("method not allowed", { status: 405 });
    }
    const slug = normalizeSlug(path.replace(/^\/+/, ""));
    if (!slug || !SLUG_RE.test(slug) || !env.LINKS) {
      return new Response("not found", { status: 404 });
    }
    const destination = await env.LINKS.get("link:" + slug);
    if (!destination) return new Response("not found", { status: 404 });

    // Approximate counter (see HONEST LIMITS above); never blocks the redirect.
    if (request.method === "GET") {
      ctx.waitUntil((async () => {
        const current = Number((await env.LINKS.get("clicks:" + slug)) || "0") || 0;
        await env.LINKS.put("clicks:" + slug, String(current + 1));
      })());
    }
    return Response.redirect(destination, 301);
  },
};
