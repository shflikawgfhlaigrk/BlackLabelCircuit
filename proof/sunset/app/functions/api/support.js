// Pages Function: POST /api/support — Sunset's on-site support helper.
//
// Grounded in Sunset's OWN published pages only. The corpus builder rejects any
// chunk carrying another property's name, domain or email, and _engine.js re-checks
// the model's output before it is ever returned — so this endpoint cannot surface
// "Black Label" or any sibling domain even if the model tries.
// Re-vendor engine + corpus: node ~/BlackLabel-Team/tools/support-agent/install.mjs

import { handleSupportRequest } from "./_engine.js";
import CORPUS from "./_corpus.json";
import { TERMS } from "./_terms.js";

const BRAND = {
  name: "Sunset",
  selfDomains: ["sunsetmixing.com"],
  forbiddenTerms: TERMS, // GENERATED from sites.mjs by install.mjs
  neutralDomains: ["apple.com", "stripe.com", "cloudflare.com"],
  brandTokens: ["sunset", "sunsetmixing", "acetate"],
  escalation: "the Sunset support page",
  escalationUrl: "/support/",
  accent: "#e8734a",
};

export async function onRequestPost(context) {
  const { request, env } = context;
  if (!env.AI) {
    return new Response(
      JSON.stringify({ answered: false, answer: "Support assistant is not configured.", sources: [] }),
      { status: 503, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } }
    );
  }
  return handleSupportRequest(request, { corpus: CORPUS.chunks, brand: BRAND, ai: env.AI });
}

export async function onRequest(context) {
  if (context.request.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "content-type": "application/json; charset=utf-8", "allow": "POST" },
    });
  }
  return onRequestPost(context);
}
