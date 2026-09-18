import assert from "node:assert/strict";
import worker, { NewsletterProgress } from "./src/index.js";

class MemoryStorage {
  constructor() { this.values = new Map(); }
  async get(key) { return this.values.get(key); }
  async put(key, value) { this.values.set(key, structuredClone(value)); }
  async delete(key) { this.values.delete(key); }
}

function durableNamespace(email) {
  const stores = new Map();
  return {
    idFromName(name) { return name; },
    get(id) {
      if (!stores.has(id)) stores.set(id, new MemoryStorage());
      const instance = new NewsletterProgress({ storage: stores.get(id) }, { EMAIL: email });
      return { fetch: (request) => instance.fetch(request) };
    },
  };
}

function payload(deliveryID, recipients) {
  return {
    from: "news@buyer.example",
    fromName: "Buyer",
    subject: "Update",
    text: "Hello",
    html: "<p>Hello</p>",
    deliveryID,
    protocolVersion: 2,
    recipients,
  };
}

async function send(env, body, token = "secret") {
  const response = await worker.fetch(new Request("https://worker.example/send", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  }), env);
  return { response, body: await response.json() };
}

let calls = 0;
const email = { async send() { calls++; } };
const env = { SEND_SECRET: "secret", EMAIL: email };
env.NEWSLETTER_PROGRESS = durableNamespace(email);

const capabilitiesResponse = await worker.fetch(new Request("https://worker.example/capabilities", {
  method: "GET", headers: { authorization: "Bearer secret" },
}), env);
const capabilities = await capabilitiesResponse.json();
assert.equal(capabilitiesResponse.status, 200);
assert.equal(capabilities.protocolVersion, 2);
assert.equal(capabilities.durableProgress, true);

// Wrong protocol is rejected before a provider call.
const oldProtocol = payload("old-protocol", ["old@x.com"]);
oldProtocol.protocolVersion = 1;
const oldProtocolResult = await send(env, oldProtocol);
assert.equal(oldProtocolResult.response.status, 426);
assert.equal(calls, 0);

// Oversized payloads are rejected before a single provider call; nothing is silently truncated.
const oversized = await send(env, payload("too-large", Array.from({ length: 101 }, (_, i) => `p${i}@x.com`)));
assert.equal(oversized.response.status, 413);
assert.equal(oversized.body.ok, false);
assert.equal(calls, 0);

// A 150-person newsletter succeeds as two explicit chunks under one stable delivery id.
const first100 = Array.from({ length: 100 }, (_, i) => `chunk${i}@x.com`);
const next50 = Array.from({ length: 50 }, (_, i) => `chunk${i + 100}@x.com`);
const chunk1 = await send(env, payload("delivery-150", first100));
const chunk2 = await send(env, payload("delivery-150", next50));
assert.equal(chunk1.response.status, 200);
assert.equal(chunk1.body.sent, 100);
assert.equal(chunk2.body.sent, 50);
assert.equal(calls, 150);

// Replaying a completed chunk is idempotent: receipts return sent, provider calls stay unchanged.
const replay = await send(env, payload("delivery-150", first100));
assert.equal(replay.body.ok, true);
assert.equal(replay.body.deduplicated, 100);
assert.equal(calls, 150);

// Partial failure returns 207. Retry calls the provider only for the failed recipient, while the
// two accepted recipients are served from durable progress.
let partialCalls = 0;
let failBOnce = true;
const partialEmail = {
  async send(message) {
    partialCalls++;
    if (message.to === "b@x.com" && failBOnce) {
      failBOnce = false;
      throw new Error("provider rejected");
    }
  },
};
const partialEnv = { SEND_SECRET: "secret", EMAIL: partialEmail };
partialEnv.NEWSLETTER_PROGRESS = durableNamespace(partialEmail);
const three = payload("partial-retry", ["a@x.com", "b@x.com", "c@x.com"]);
const partial = await send(partialEnv, three);
assert.equal(partial.response.status, 207);
assert.equal(partial.body.ok, false);
assert.equal(partial.body.sent, 2);
assert.equal(partial.body.failed, 1);
assert.equal(partialCalls, 3);

const retried = await send(partialEnv, three);
assert.equal(retried.response.status, 200);
assert.equal(retried.body.ok, true);
assert.equal(retried.body.delivered, 1);
assert.equal(retried.body.deduplicated, 2);
assert.equal(partialCalls, 4);

await send(partialEnv, three);
assert.equal(partialCalls, 4);

// If the provider accepts but the durable "sent" write fails, the provisional marker is retained.
// A retry is held instead of duplicating an outcome whose receipt is uncertain.
class ConfirmationFailStorage extends MemoryStorage {
  async put(key, value) {
    if (value?.status === "sent") throw new Error("storage unavailable");
    return super.put(key, value);
  }
}
let uncertainCalls = 0;
const uncertainEmail = { async send() { uncertainCalls++; } };
const uncertainStorage = new ConfirmationFailStorage();
const uncertainObject = new NewsletterProgress({ storage: uncertainStorage }, { EMAIL: uncertainEmail });
const uncertainRequest = () => new Request("https://newsletter-progress.internal/send", {
  method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify(payload("uncertain", ["uncertain@x.com"])),
});
const uncertainFirst = await uncertainObject.fetch(uncertainRequest());
assert.equal(uncertainFirst.status, 502);
assert.equal(uncertainCalls, 1);
const uncertainRetry = await uncertainObject.fetch(uncertainRequest());
assert.equal(uncertainRetry.status, 502);
assert.equal(uncertainCalls, 1);

// Durable progress is a hard gate: without it, the Worker fails before EMAIL.send.
const missingBindingCalls = calls;
const missingBinding = await send({ SEND_SECRET: "secret", EMAIL: email }, payload("missing-binding", ["one@x.com"]));
assert.equal(missingBinding.response.status, 503);
assert.equal(calls, missingBindingCalls);

console.log("ALL NEWSLETTER WORKER CONTRACT TESTS PASSED");
