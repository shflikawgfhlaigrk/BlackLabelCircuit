// Canonical-host enforcement. Pages `_redirects` cannot match on hostname
// (path-only sources), so the www alias is folded here before any asset or
// API function runs.
export async function onRequest({ request, next }) {
  const url = new URL(request.url);
  if (url.protocol === "http:" || url.hostname === "www.sunsetmixing.com") {
    url.protocol = "https:";
    url.hostname = "sunsetmixing.com";
    return new Response(null, {
      status: 308,
      headers: {
        Location: url.toString(),
        "Strict-Transport-Security": "max-age=63072000; includeSubDomains; preload",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "strict-origin-when-cross-origin",
      },
    });
  }
  // A route-level guard remains authoritative even when a retained recovery ZIP
  // exists in the static tree. This prevents an exact asset match from ever
  // bypassing the account redirect declared in web/_redirects.
  if (url.pathname === "/dl" || url.pathname.startsWith("/dl/")) {
    url.pathname = "/account";
    url.search = "";
    return Response.redirect(url.toString(), 302);
  }
  return next();
}
