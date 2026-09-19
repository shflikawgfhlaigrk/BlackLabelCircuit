const OBJECT_KEY =
  "e3745b7ee1813c317a3c4cf2d92b0bb0fb5409ff87d05ef7/Ace-1.14-build31.dmg";
const DOWNLOAD_PATH = `/${OBJECT_KEY}`;
const MAX_PART_BYTES = 90 * 1024 * 1024;

function authorized(request, env) {
  const expected = env.UPLOAD_TOKEN?.trim();
  return Boolean(expected) && request.headers.get("Authorization") === `Bearer ${expected}`;
}

function json(value, status = 200) {
  return Response.json(value, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === DOWNLOAD_PATH) {
      const object = await env.DOWNLOADS.get(OBJECT_KEY);
      if (!object) return new Response("Not found", { status: 404 });
      const headers = new Headers();
      object.writeHttpMetadata(headers);
      headers.set("Content-Length", String(object.size));
      headers.set("ETag", object.httpEtag);
      headers.set("Cache-Control", "private, max-age=0, no-store");
      return new Response(object.body, { headers });
    }

    if (!authorized(request, env)) {
      return new Response("Not found", { status: 404 });
    }

    if (request.method === "POST" && url.pathname === "/_upload/start") {
      const upload = await env.DOWNLOADS.createMultipartUpload(OBJECT_KEY, {
        httpMetadata: {
          contentType: "application/x-apple-diskimage",
          contentDisposition: 'attachment; filename="Ace-1.14-build31.dmg"',
          cacheControl: "private, max-age=0, no-store",
        },
        customMetadata: {
          sha256: "79ab8e9f5b75e7a4e7dd68329314994c0119cd62e1090068302132b849232b17",
          source: "9d450a36b5032a4a80f6d6b808b23b98b3abc860fa882a8f5ed92beb1999f982",
        },
      });
      return json({ key: upload.key, uploadId: upload.uploadId });
    }

    if (request.method === "PUT" && url.pathname.startsWith("/_upload/part/")) {
      const uploadId = url.searchParams.get("uploadId") || "";
      const partNumber = Number(url.pathname.slice("/_upload/part/".length));
      const contentLength = Number(request.headers.get("Content-Length") || "0");
      if (
        !uploadId ||
        !Number.isInteger(partNumber) ||
        partNumber < 1 ||
        partNumber > 10000 ||
        contentLength < 1 ||
        contentLength > MAX_PART_BYTES ||
        !request.body
      ) {
        return json({ error: "Invalid upload part" }, 400);
      }
      const upload = env.DOWNLOADS.resumeMultipartUpload(OBJECT_KEY, uploadId);
      const part = await upload.uploadPart(partNumber, request.body);
      return json({ partNumber: part.partNumber, etag: part.etag });
    }

    if (request.method === "POST" && url.pathname === "/_upload/complete") {
      const uploadId = url.searchParams.get("uploadId") || "";
      const payload = await request.json();
      const parts = Array.isArray(payload?.parts) ? payload.parts : [];
      const ordered = parts.every(
        (part, index) =>
          part?.partNumber === index + 1 &&
          typeof part?.etag === "string" &&
          part.etag.length > 0,
      );
      if (!uploadId || parts.length < 2 || !ordered) {
        return json({ error: "Invalid completion manifest" }, 400);
      }
      const upload = env.DOWNLOADS.resumeMultipartUpload(OBJECT_KEY, uploadId);
      const object = await upload.complete(parts);
      return json({ key: object.key, size: object.size, etag: object.etag });
    }

    if (request.method === "DELETE" && url.pathname === "/_upload") {
      const uploadId = url.searchParams.get("uploadId") || "";
      if (!uploadId) return json({ error: "Missing upload id" }, 400);
      const upload = env.DOWNLOADS.resumeMultipartUpload(OBJECT_KEY, uploadId);
      await upload.abort();
      return new Response(null, { status: 204 });
    }

    return new Response("Not found", { status: 404 });
  },
};
