const OBJECT_KEY =
  "b45942df86830b5ce4b1a1beda1995231f7ee7c3cb32df5e/Ace-1.14-build33.dmg";
const MAX_PART_BYTES = 90 * 1024 * 1024;

function authorized(request, env) {
  const expected = env.UPLOAD_TOKEN_V2?.trim();
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
    if (!authorized(request, env)) {
      return new Response("Not found", { status: 404 });
    }

    if (request.method === "POST" && url.pathname === "/_upload/start") {
      const upload = await env.DOWNLOADS.createMultipartUpload(OBJECT_KEY, {
        httpMetadata: {
          contentType: "application/x-apple-diskimage",
          contentDisposition: 'attachment; filename="Ace-1.14-build33.dmg"',
          cacheControl: "private, max-age=0, no-store",
        },
        customMetadata: {
          sha256: "2a0e5bd306d5435e5baf03c01e0c880b2124a3538978e966ea1f4441b0b022a4",
          source: "9fdfc83046461148c1616e2e2a32de929bcef3998f8cef0854950eba969a678e",
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
