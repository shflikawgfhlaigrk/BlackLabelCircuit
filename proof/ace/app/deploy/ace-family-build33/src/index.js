const OBJECT_KEY =
  "b45942df86830b5ce4b1a1beda1995231f7ee7c3cb32df5e/Ace-1.14-build33.dmg";
const DOWNLOAD_PATH = `/${OBJECT_KEY}`;

function headersFor(object) {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("Content-Type", "application/x-apple-diskimage");
  headers.set(
    "Content-Disposition",
    'attachment; filename="Ace-1.14-build33.dmg"',
  );
  headers.set("Cache-Control", "private, max-age=0, no-store");
  headers.set("Content-Length", String(object.size));
  headers.set("ETag", object.httpEtag);
  headers.set("X-Content-Type-Options", "nosniff");
  return headers;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== DOWNLOAD_PATH) {
      return new Response("Not found", { status: 404 });
    }

    if (request.method === "HEAD") {
      const object = await env.DOWNLOADS.head(OBJECT_KEY);
      return object
        ? new Response(null, { status: 200, headers: headersFor(object) })
        : new Response("Not found", { status: 404 });
    }

    if (request.method !== "GET") {
      return new Response("Method not allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }

    const object = await env.DOWNLOADS.get(OBJECT_KEY);
    if (!object) {
      return new Response("Not found", { status: 404 });
    }
    return new Response(object.body, {
      status: 200,
      headers: headersFor(object),
    });
  },
};
