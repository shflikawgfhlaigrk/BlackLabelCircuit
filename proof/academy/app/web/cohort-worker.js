// Black Label Academy — AC-09 anonymous cohort server (Cloudflare Worker + KV).
//
// The smallest honest thing that makes the "learn alongside others" completion lever real: it stores
// ANONYMOUS join tokens and per-lesson completion counts and hands back a peer-progress signal. It
// holds NO PII — no email, no name — only a random device token the app minted locally, used solely
// to keep completion counts idempotent (finishing a lesson twice never double-counts).
//
// Endpoints (all JSON):
//   POST /api/cohort/join      {token}                       -> {cohort_id, start_date}
//   POST /api/cohort/complete  {cohort_id, lesson_id, token} -> {ok}
//   GET  /api/cohort/signal?cohort_id=&lesson_id=            -> {active, cohort_id, lesson_id,
//                                                                others_finished, cohort_size}
//
// HONESTY: `others_finished` is a real count from KV; when a cohort has no members or no completions
// the server returns the true numbers (0), and for an unknown cohort it returns {active:false} so the
// app shows its honest "No cohort running yet" state. The Worker never invents a count.
//
// DEPLOY: this is web-producer's lane. Bind a KV namespace as `COHORT` in wrangler config. The app's
// AcademyConfig.cohortBaseURL points at https://blacklabelbots.com/api/cohort (override via the
// UserDefaults key bl.academy.cohort_url). Cohort PRICING is a founder money gate — this server
// charges nothing and knows nothing about billing.
//
// KV KEYS:
//   member:<cohort_id>:<token>                = "1"           (set membership; counted for cohort_size)
//   done:<cohort_id>:<lesson_id>:<token>      = "1"           (idempotent per-member-per-lesson)
//   count:<cohort_id>:<lesson_id>             = "<int>"       (denormalized completion count)
//   size:<cohort_id>                          = "<int>"       (denormalized member count)

const json = (o, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

// The single active cohort window. A real rollout rotates this (a weekly start date); kept as one
// deterministic open cohort so the server is honest and stateless about "which cohort is open now".
const OPEN_COHORT_ID = "cohort-open";
const OPEN_COHORT_START = "2026-07-13T00:00:00Z";

async function readInt(kv, key) {
  const v = await kv.get(key);
  const n = v == null ? 0 : parseInt(v, 10);
  return Number.isFinite(n) && n >= 0 ? n : 0;
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const p = url.pathname;
    const kv = env.COHORT; // KV namespace binding

    if (!kv) return json({ error: "cohort store not configured" }, 503);

    // POST /join — enroll an anonymous token into the open cohort (idempotent).
    if (req.method === "POST" && p.endsWith("/api/cohort/join")) {
      let body;
      try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }
      const token = String(body.token || "").trim();
      if (!token) return json({ error: "token required" }, 400);
      const memberKey = `member:${OPEN_COHORT_ID}:${token}`;
      const existing = await kv.get(memberKey);
      if (!existing) {
        await kv.put(memberKey, "1");
        const size = (await readInt(kv, `size:${OPEN_COHORT_ID}`)) + 1;
        await kv.put(`size:${OPEN_COHORT_ID}`, String(size));
      }
      return json({ cohort_id: OPEN_COHORT_ID, start_date: OPEN_COHORT_START });
    }

    // POST /complete — record that an anonymous member finished a lesson (idempotent per member+lesson).
    if (req.method === "POST" && p.endsWith("/api/cohort/complete")) {
      let body;
      try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }
      const cohortId = String(body.cohort_id || "").trim();
      const lessonId = String(body.lesson_id || "").trim();
      const token = String(body.token || "").trim();
      if (!cohortId || !lessonId || !token) return json({ error: "cohort_id, lesson_id, token required" }, 400);
      // Only a real member may increment; and only once per lesson.
      const isMember = await kv.get(`member:${cohortId}:${token}`);
      if (!isMember) return json({ ok: false, reason: "not a member" }, 403);
      const doneKey = `done:${cohortId}:${lessonId}:${token}`;
      if (await kv.get(doneKey)) return json({ ok: true, already: true });
      await kv.put(doneKey, "1");
      const count = (await readInt(kv, `count:${cohortId}:${lessonId}`)) + 1;
      await kv.put(`count:${cohortId}:${lessonId}`, String(count));
      return json({ ok: true });
    }

    // GET /signal — the honest peer-progress signal for a lesson. `others_finished` EXCLUDES the
    // caller (the app subtracts nothing; the server does not know the caller here, so it returns the
    // raw completion count and the app renders "N others" — the caller's own completion is reported
    // via /complete and the app never counts itself in the rendered line).
    if (req.method === "GET" && p.endsWith("/api/cohort/signal")) {
      const cohortId = String(url.searchParams.get("cohort_id") || "").trim();
      const lessonId = String(url.searchParams.get("lesson_id") || "").trim();
      if (!cohortId || !lessonId) return json({ error: "cohort_id and lesson_id required" }, 400);
      const size = await readInt(kv, `size:${cohortId}`);
      if (size === 0) return json({ active: false }); // unknown/empty cohort -> honest "not running yet"
      const finished = await readInt(kv, `count:${cohortId}:${lessonId}`);
      // Never report more finishers than members exist (structural honesty; mirrors the app's validate).
      const others = Math.max(0, Math.min(finished, Math.max(0, size - 1)));
      return json({
        active: true,
        cohort_id: cohortId,
        lesson_id: lessonId,
        others_finished: others,
        cohort_size: size,
      });
    }

    return new Response("Not found", { status: 404 });
  },
};
