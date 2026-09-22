import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { ConversionBroker, createMinimizedBundleManifest, OnlineBrokerClient } from '../lib/conversion-broker.js';

const hash = (value) => crypto.createHash('sha256').update(value).digest('hex');
const digest = hash('fixture');

function broker(t, options = {}) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-broker-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  return new ConversionBroker({ base, ...options });
}

function canaries() {
  return {
    deterministicBuild: { passed: true },
    exactOutput: { passed: true, expected: 'CIRCUIT-CANARY', actual: 'CIRCUIT-CANARY' },
    artifactReturn: { passed: true, sha256: digest, cleanupReceipt: { deleted: true } },
  };
}

function admit(instance, id = 'windows-01', workerPlatform = 'windows') {
  return instance.admitWorker({
    id, platform: workerPlatform, endpoint: 'https://worker.example/v1',
    inventory: { os: 'Windows 11', cpu: 'x64', ramBytes: 16e9, freeDiskBytes: 80e9, encrypted: true, toolchains: ['msbuild', 'swift'] },
    canaries: canaries(), publicKeyId: 'worker-key-01',
  });
}

function createQueued(instance, targetPlatform = 'windows') {
  let job = instance.createJob({
    conversionId: 'conversion-01', inputManifestSha256: digest,
    sourcePlatform: targetPlatform === 'windows' ? 'macos' : 'windows', targetPlatform,
    targetProfile: targetPlatform === 'windows' ? 'winui3' : 'swiftui',
    bundle: { sha256: digest, size: 7, chunks: 1 },
  });
  job = instance.recordUploadedChunk(job.id, { index: 0, sha256: digest, size: 7 });
  assert.equal(job.status, 'queued');
  return job;
}

function auth(job) {
  return { workerId: job.worker.id, operationNonce: job.operationNonce, fencingToken: job.fencingToken };
}

test('admits only inventoried encrypted workers that pass all three canaries', (t) => {
  const instance = broker(t);
  const worker = admit(instance);
  assert.equal(worker.status, 'admitted');
  assert.equal(instance.listWorkers().length, 1);
  assert.throws(() => instance.admitWorker({
    id: 'bad', platform: 'macos', endpoint: 'http://remote.example',
    inventory: { os: 'macOS', cpu: 'arm64', ramBytes: 1, freeDiskBytes: 1, encrypted: false, toolchains: [] }, canaries: canaries(),
  }), /inventory|HTTPS/);
});

test('submits, uploads, claims, progresses, returns artifacts and seals proof', (t) => {
  const instance = broker(t);
  admit(instance);
  let job = createQueued(instance);
  const originalNonce = job.operationNonce;
  job = instance.claimJob(job.id, { workerId: 'windows-01', operationNonce: originalNonce });
  assert.equal(job.status, 'running');
  assert.equal(job.fencingToken, 1);
  job = instance.updateProgress(job.id, auth(job), { stage: 'compile', completed: 1, total: 4, message: 'Compiling on Windows' });
  const artifact = Buffer.from('real-target-artifact');
  const saved = instance.storeArtifact(job.id, auth(job), { name: 'App.msix', bytes: artifact, expectedSha256: hash(artifact) });
  assert.equal(fs.readFileSync(saved.path, 'utf8'), 'real-target-artifact');
  const receipt = { passed: true, sha256: digest };
  job = instance.completeJob(job.id, auth(job), {
    evidence: { compile: receipt, install: receipt, launch: receipt, parity: receipt },
    cleanupReceipt: { deleted: true, operationNonce: originalNonce },
  });
  assert.equal(job.status, 'complete');
  assert.equal(job.artifacts[0].sha256, hash(artifact));
  assert.equal(instance.loadJob(job.id).status, 'complete', 'job survives broker restart/readback');
});

test('hash mismatch is rejected without recording an artifact', (t) => {
  const instance = broker(t);
  admit(instance);
  const queued = createQueued(instance);
  const job = instance.claimJob(queued.id, { workerId: 'windows-01', operationNonce: queued.operationNonce });
  assert.throws(() => instance.storeArtifact(job.id, auth(job), { name: 'bad.msix', bytes: Buffer.from('bad'), expectedSha256: digest }), /hash mismatch/);
  assert.deepEqual(instance.loadJob(job.id).artifacts, []);
  assert.throws(() => instance.updateProgress(job.id, { ...auth(job), fencingToken: job.fencingToken - 1 }, { stage: 'compile', completed: 1, total: 4 }), /stale/);
});

test('host loss fences the worker, invalidates returned artifacts and requeues safely', (t) => {
  const instance = broker(t);
  admit(instance);
  const queued = createQueued(instance);
  let job = instance.claimJob(queued.id, { workerId: 'windows-01', operationNonce: queued.operationNonce });
  const oldAuth = auth(job);
  const artifact = Buffer.from('unverified');
  instance.storeArtifact(job.id, oldAuth, { name: 'candidate.msix', bytes: artifact, expectedSha256: hash(artifact) });
  job = instance.markHostLost(job.id, 'windows-01');
  assert.equal(job.status, 'queued');
  assert.equal(job.artifacts.length, 0);
  assert.equal(job.invalidatedArtifacts.length, 1);
  assert.notEqual(job.operationNonce, oldAuth.operationNonce);
  assert.throws(() => instance.updateProgress(job.id, oldAuth, { stage: 'late', completed: 1, total: 1 }), /queued|stale|unauthorized/);
});

test('cancellation is durable, terminal and invalidates the operation nonce', (t) => {
  const instance = broker(t);
  const queued = createQueued(instance, 'macos');
  const cancelled = instance.cancelJob(queued.id);
  assert.equal(cancelled.status, 'cancelled');
  assert.notEqual(cancelled.operationNonce, queued.operationNonce);
  assert.equal(instance.cancelJob(queued.id).status, 'cancelled');
});

test('online client uses the configured broker for submit, status and cancellation', async () => {
  const calls = [];
  const request = async (url, options = {}) => {
    calls.push({ url, options });
    return { ok: true, status: 200, json: async () => ({ id: 'job-01', status: 'queued' }) };
  };
  const client = new OnlineBrokerClient({ endpoint: 'https://broker.example/api/', request });
  await client.submit({ conversionId: 'c1' });
  await client.status('job-01');
  await client.cancel('job-01', 'nonce');
  assert.deepEqual(calls.map((call) => [call.url, call.options.method ?? 'GET']), [
    ['https://broker.example/api/v1/conversion-jobs', 'POST'],
    ['https://broker.example/api/v1/conversion-jobs/job-01', 'GET'],
    ['https://broker.example/api/v1/conversion-jobs/job-01/cancel', 'POST'],
  ]);
});

test('minimized bundle is deterministic and excludes build output and secret-bearing files', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-bundle-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'Sources'), { recursive: true });
  fs.mkdirSync(path.join(root, 'node_modules', 'ignored'), { recursive: true });
  fs.writeFileSync(path.join(root, 'Sources', 'App.swift'), 'print("ok")\n');
  fs.writeFileSync(path.join(root, '.env'), 'SHOULD_NOT_SHIP=true\n');
  fs.writeFileSync(path.join(root, 'node_modules', 'ignored', 'index.js'), 'ignored');
  const first = createMinimizedBundleManifest(root);
  const second = createMinimizedBundleManifest(root);
  assert.equal(first.sha256, second.sha256);
  assert.deepEqual(first.publicFiles.map((file) => file.path), ['Sources/App.swift']);
  assert.ok(first.files[0].absolutePath.endsWith('Sources/App.swift'));
});

test('minimized bundle fails closed when an ordinary source file contains a credential', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'circuit-bundle-secret-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.writeFileSync(path.join(root, 'config.js'), 'const password = "this-is-a-real-hardcoded-password";\n');
  assert.throws(() => createMinimizedBundleManifest(root), /potential credential/);
});
