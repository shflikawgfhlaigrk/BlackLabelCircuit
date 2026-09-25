// Circuit licensing — honest, fail-closed.
//
// Circuit is a paid product. The app runs the FULL, real analyzer as a
// demo/trial so a prospect can grade their OWN repository before buying —
// nothing is faked or gated behind a canned score. Until a valid license is
// present the build stays in demo mode and surfaces a purchase CTA.
//
// FAIL-CLOSED: anything missing, blank, or an obvious placeholder resolves to
// `demo`. We never assume licensed by default.
//
// NO PRICE IS MINTED HERE. Michael has not ruled the Circuit price model, and
// the storefront currently shows conflicting states — so the app names the
// model ("paid license") and points at the product page, but encodes zero
// dollar figure anywhere. The number lives on the product page only.
//
// Zero runtime dependency (Node stdlib only), consistent with the §3
// zero-dependency backend rule. We deliberately do NOT phone home or verify a
// signature: no secret ships in the bundle, and real activation is a storefront
// concern gated on the price ruling. The honest posture is "demo unless the
// buyer sets their own key."

export const PRODUCT_URL_DEFAULT = 'https://blacklabelbots.com/circuit';

// Obvious non-keys that must resolve to demo even if someone sets the env var.
const PLACEHOLDERS = new Set(['demo', 'trial', 'none', 'test', 'changeme', 'false', '0', 'null', 'undefined']);

// Config-driven so the storefront can move without a reship. Never a price.
export function productUrl(env = process.env) {
  const v = String(env.CIRCUIT_PRODUCT_URL ?? '').trim();
  return v || PRODUCT_URL_DEFAULT;
}

// A license is only "active" when an explicit, non-trivial key is provided that
// is not a known placeholder. Everything else => demo. Fail-closed by design.
export function isLicensed(env = process.env) {
  const raw = String(env.CIRCUIT_LICENSE ?? '').trim();
  return raw.length >= 8 && !PLACEHOLDERS.has(raw.toLowerCase());
}

// The full license state the server hands the UI. All copy here is
// intentionally price-free — assert-tested to contain no dollar figure.
export function resolveLicense(env = process.env) {
  const licensed = isLicensed(env);
  return {
    product: 'Circuit',
    mode: licensed ? 'licensed' : 'demo',
    licensed,
    // States the model without a number, and claims no gate the code doesn't
    // enforce: the demo is the full analyzer and nothing expires — buying is a
    // license-terms requirement, not a technical cutoff.
    notice: licensed ? null : 'Demo build — the full analyzer, free to evaluate. Ongoing use requires a paid license.',
    cta: licensed ? null : 'Get a license',
    productUrl: productUrl(env),
  };
}
