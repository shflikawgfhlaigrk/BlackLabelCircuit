const OBJECT_PREFIX =
  "e9c9cd921fea522819d3a0b5c7d0a294748a874cbdf273b/Ace-1.14-build39.dmg";
const DOWNLOAD_PATH = `/${OBJECT_PREFIX}`;
const PART_KEYS = [0, 1, 2].map((part) => `${OBJECT_PREFIX}.part${part}`);
const PART_SIZES = [293601280, 293601280, 225168613];
const TOTAL_BYTES = 812371173;
const DMG_SHA256 =
  "5e3b4de08d346f66996aff389eaf3d085cf5b3cc1e2d3d4f06a701fc487ec4e5";

function headersFor() {
  const headers = new Headers();
  headers.set("Content-Type", "application/x-apple-diskimage");
  headers.set(
    "Content-Disposition",
    'attachment; filename="Ace-1.14-build39.dmg"',
  );
  headers.set("Cache-Control", "private, max-age=0, no-store");
  headers.set("Content-Length", String(TOTAL_BYTES));
  headers.set("ETag", `"${DMG_SHA256}"`);
  headers.set("X-Content-Type-Options", "nosniff");
  return headers;
}

async function loadExactParts(env, headOnly) {
  const parts = await Promise.all(
    PART_KEYS.map((key) =>
      headOnly ? env.DOWNLOADS.head(key) : env.DOWNLOADS.get(key),
    ),
  );
  if (
    parts.some(
      (part, index) => !part || part.size !== PART_SIZES[index],
    )
  ) {
    return null;
  }
  return parts;
}

function concatenateBodies(parts) {
  let partIndex = 0;
  let reader = null;
  return new ReadableStream({
    async pull(controller) {
      while (partIndex < parts.length) {
        reader ??= parts[partIndex].body.getReader();
        const { done, value } = await reader.read();
        if (!done) {
          controller.enqueue(value);
          return;
        }
        reader.releaseLock();
        reader = null;
        partIndex += 1;
      }
      controller.close();
    },
    async cancel(reason) {
      if (reader) await reader.cancel(reason);
    },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== DOWNLOAD_PATH) {
      return new Response("Not found", { status: 404 });
    }

    if (request.method === "HEAD") {
      const parts = await loadExactParts(env, true);
      return parts
        ? new Response(null, { status: 200, headers: headersFor() })
        : new Response("Not found", { status: 404 });
    }

    if (request.method !== "GET") {
      return new Response("Method not allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }

    const parts = await loadExactParts(env, false);
    if (!parts) {
      return new Response("Not found", { status: 404 });
    }
    return new Response(concatenateBodies(parts), {
      status: 200,
      headers: headersFor(),
    });
  },
};
