import crypto, { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { scanSecrets } from './lang/common.js';

export const BROKER_SCHEMA = 'circuit.conversion-broker.v1';
export const JOB_SCHEMA = 'circuit.conversion-job.v1';
export const WORKER_SCHEMA = 'circuit.conversion-worker.v1';
export const PLATFORMS = Object.freeze(['macos', 'windows']);
const TERMINAL = new Set(['complete', 'failed', 'cancelled']);
const BUNDLE_IGNORE_DIRS = new Set(['.git', '.build', 'build', 'DerivedData', 'node_modules', 'Pods', 'dist', 'vendor']);
const SECRET_FILE = /(^|\/)(?:\.env(?:\..*)?|credentials?(?:\..*)?|auth\.json|.*\.(?:p12|pfx|pem|key))$/i;

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function atomicJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.${randomUUID()}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function platform(value, name) {
  if (!PLATFORMS.includes(value)) throw new Error(`${name} must be macos or windows`);
  return value;
}

function digest(value, name) {
  if (!/^[a-f0-9]{64}$/.test(String(value))) throw new Error(`${name} must be a SHA-256 digest`);
  return value;
}

function safeId(value, name) {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/.test(String(value))) throw new Error(`invalid ${name}`);
  return String(value);
}

function endpoint(value) {
  const parsed = new URL(value);
  if (parsed.protocol !== 'https:' && !(parsed.protocol === 'http:' && ['127.0.0.1', 'localhost', '::1'].includes(parsed.hostname))) {
    throw new Error('worker endpoint must use HTTPS or loopback HTTP');
  }
  return parsed.toString().replace(/\/$/, '');
}

function verifyAdmissionCanaries(canaries) {
  if (!canaries || canaries.deterministicBuild?.passed !== true) throw new Error('deterministic build canary did not pass');
  if (canaries.exactOutput?.passed !== true || canaries.exactOutput?.expected !== canaries.exactOutput?.actual) throw new Error('exact-output canary did not pass');
  if (canaries.artifactReturn?.passed !== true) throw new Error('artifact-return canary did not pass');
  digest(canaries.artifactReturn.sha256, 'artifact-return canary digest');
  if (canaries.artifactReturn.cleanupReceipt?.deleted !== true) throw new Error('artifact-return cleanup receipt is missing');
}

function proofReceipt(value, name) {
  if (!value || value.passed !== true) throw new Error(`${name} receipt did not pass`);
  digest(value.sha256, `${name} receipt digest`);
  return value;
}

export function createMinimizedBundleManifest(root, { maxFileBytes = 64 * 1024 * 1024, maxTotalBytes = 2 * 1024 * 1024 * 1024 } = {}) {
  const realRoot = fs.realpathSync(root);
  const files = [];
  let total = 0;
  function visit(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.isDirectory() && BUNDLE_IGNORE_DIRS.has(entry.name)) continue;
      const abs = path.join(dir, entry.name);
      const rel = path.relative(realRoot, abs).split(path.sep).join('/');
      if (entry.isDirectory()) visit(abs);
      else if (entry.isFile() && !SECRET_FILE.test(rel)) {
        const stat = fs.statSync(abs);
        if (stat.size > maxFileBytes) continue;
        if (stat.size <= 2 * 1024 * 1024) {
          const contents = fs.readFileSync(abs, 'utf8');
          if (scanSecrets(contents).length) throw new Error(`minimized source bundle contains a potential credential in ${rel}`);
        }
        total += stat.size;
        if (total > maxTotalBytes) throw new Error('minimized source bundle exceeds the configured size limit');
        files.push({ index: files.length, path: rel, size: stat.size, sha256: sha256(fs.readFileSync(abs)), absolutePath: abs });
      }
    }
  }
  visit(realRoot);
  const publicFiles = files.map(({ absolutePath, ...file }) => file);
  const manifestSha256 = sha256(JSON.stringify(publicFiles));
  return { schema: 'circuit.source-bundle.v1', root: realRoot, size: total, chunks: files.length, sha256: manifestSha256, files, publicFiles };
}

export class ConversionBroker {
  constructor({ base, now = () => Date.now() }) {
    this.base = path.resolve(base);
    this.now = now;
    this.jobsDir = path.join(this.base, 'jobs');
    this.workersDir = path.join(this.base, 'workers');
    this.artifactsDir = path.join(this.base, 'artifacts');
    this.metaFile = path.join(this.base, 'broker.json');
    fs.mkdirSync(this.base, { recursive: true });
    if (!fs.existsSync(this.metaFile)) atomicJson(this.metaFile, { schema: BROKER_SCHEMA, fencing: {} });
  }

  #workerFile(id) { return path.join(this.workersDir, `${safeId(id, 'worker id')}.json`); }
  #jobFile(id) {
    if (!/^[0-9a-f-]{36}$/.test(String(id))) throw new Error('invalid conversion job id');
    return path.join(this.jobsDir, `${id}.json`);
  }
  #writeJob(job) { atomicJson(this.#jobFile(job.id), job); return job; }
  #nextFence(scope) {
    const meta = readJson(this.metaFile);
    meta.fencing[scope] = (meta.fencing[scope] ?? 0) + 1;
    atomicJson(this.metaFile, meta);
    return meta.fencing[scope];
  }

  admitWorker({ id, platform: workerPlatform, endpoint: workerEndpoint, inventory, canaries, publicKeyId = null }) {
    const workerId = safeId(id, 'worker id');
    platform(workerPlatform, 'worker platform');
    if (!inventory || !inventory.os || !inventory.cpu || !Number.isFinite(inventory.ramBytes) || !Number.isFinite(inventory.freeDiskBytes) || inventory.encrypted !== true || !Array.isArray(inventory.toolchains)) {
      throw new Error('worker inventory is incomplete or disk encryption is not confirmed');
    }
    verifyAdmissionCanaries(canaries);
    const admittedAt = new Date(this.now()).toISOString();
    const worker = {
      schema: WORKER_SCHEMA, id: workerId, platform: workerPlatform,
      endpoint: endpoint(workerEndpoint), inventory, canaries, publicKeyId,
      status: 'admitted', admittedAt, lastSeenAt: admittedAt,
      admissionSha256: sha256(JSON.stringify({ id: workerId, platform: workerPlatform, inventory, canaries, publicKeyId })),
    };
    atomicJson(this.#workerFile(workerId), worker);
    return worker;
  }

  listWorkers() {
    if (!fs.existsSync(this.workersDir)) return [];
    return fs.readdirSync(this.workersDir).filter((name) => name.endsWith('.json')).sort().map((name) => readJson(path.join(this.workersDir, name)));
  }

  createJob({ conversionId, inputManifestSha256, sourcePlatform, targetPlatform, targetProfile, bundle }) {
    platform(sourcePlatform, 'source platform');
    platform(targetPlatform, 'target platform');
    if (sourcePlatform === targetPlatform) throw new Error('source and target platforms must differ');
    digest(inputManifestSha256, 'input manifest digest');
    if (!bundle || !Number.isInteger(bundle.size) || bundle.size < 0) throw new Error('bundle metadata is required');
    digest(bundle.sha256, 'bundle digest');
    const createdAt = new Date(this.now()).toISOString();
    const job = {
      schema: JOB_SCHEMA, id: randomUUID(), conversionId: safeId(conversionId, 'conversion id'),
      inputManifestSha256, sourcePlatform, targetPlatform, targetProfile: safeId(targetProfile, 'target profile'),
      bundle: { ...bundle, uploadedChunks: [] }, operationNonce: crypto.randomBytes(32).toString('hex'),
      status: 'uploading', worker: null, fencingToken: null, leaseExpiresAt: null,
      progress: { stage: 'upload', completed: 0, total: bundle.chunks ?? 1, message: 'Uploading minimized source bundle' },
      artifacts: [], evidence: null, cleanupReceipt: null, invalidatedArtifacts: [],
      createdAt, updatedAt: createdAt, finishedAt: null, error: null,
    };
    return this.#writeJob(job);
  }

  loadJob(id) { return readJson(this.#jobFile(id)); }

  recordUploadedChunk(id, { index, sha256: chunkSha256, size }) {
    const job = this.loadJob(id);
    if (job.status !== 'uploading') throw new Error('job is not accepting uploads');
    if (!Number.isInteger(index) || index < 0 || !Number.isInteger(size) || size < 0) throw new Error('invalid upload chunk');
    digest(chunkSha256, 'chunk digest');
    const chunks = job.bundle.uploadedChunks.filter((item) => item.index !== index);
    chunks.push({ index, sha256: chunkSha256, size });
    chunks.sort((a, b) => a.index - b.index);
    job.bundle.uploadedChunks = chunks;
    job.progress.completed = chunks.length;
    if (chunks.length === job.progress.total) {
      job.status = 'queued';
      job.progress = { stage: 'queued', completed: 0, total: 1, message: `Waiting for an admitted ${job.targetPlatform} worker` };
    }
    job.updatedAt = new Date(this.now()).toISOString();
    return this.#writeJob(job);
  }

  claimJob(id, { workerId, operationNonce, leaseMs = 300000 }) {
    const job = this.loadJob(id);
    if (job.status !== 'queued') throw new Error('job is not queued');
    if (job.operationNonce !== operationNonce) throw new Error('operation nonce mismatch');
    const worker = readJson(this.#workerFile(workerId));
    if (worker.status !== 'admitted' || worker.platform !== job.targetPlatform) throw new Error('worker is not admitted for this target platform');
    const fencingToken = this.#nextFence(`${job.targetPlatform}:${worker.id}`);
    job.status = 'running';
    job.worker = { id: worker.id, platform: worker.platform, admissionSha256: worker.admissionSha256 };
    job.fencingToken = fencingToken;
    job.leaseExpiresAt = this.now() + leaseMs;
    job.progress = { stage: 'claim', completed: 0, total: 4, message: `Claimed by ${worker.id}` };
    job.updatedAt = new Date(this.now()).toISOString();
    return this.#writeJob(job);
  }

  #assertOwner(job, auth) {
    if (TERMINAL.has(job.status)) throw new Error('job is terminal');
    if (!job.worker || job.worker.id !== auth.workerId || job.operationNonce !== auth.operationNonce || job.fencingToken !== auth.fencingToken) throw new Error('stale or unauthorized worker update');
    if (job.leaseExpiresAt <= this.now()) throw new Error('worker lease expired');
  }

  updateProgress(id, auth, progress) {
    const job = this.loadJob(id);
    this.#assertOwner(job, auth);
    if (!progress || !Number.isInteger(progress.completed) || !Number.isInteger(progress.total) || progress.completed < 0 || progress.total < 1 || progress.completed > progress.total) throw new Error('invalid job progress');
    job.progress = { stage: safeId(progress.stage, 'progress stage'), completed: progress.completed, total: progress.total, message: String(progress.message ?? '').slice(0, 500) };
    job.updatedAt = new Date(this.now()).toISOString();
    return this.#writeJob(job);
  }

  storeArtifact(id, auth, { name, bytes, expectedSha256 }) {
    const job = this.loadJob(id);
    this.#assertOwner(job, auth);
    const fileName = safeId(name, 'artifact name');
    const buffer = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);
    const actual = sha256(buffer);
    if (actual !== digest(expectedSha256, 'expected artifact digest')) throw new Error('artifact hash mismatch');
    const dir = path.join(this.artifactsDir, job.id, String(job.fencingToken));
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, fileName);
    fs.writeFileSync(file, buffer, { mode: 0o600 });
    job.artifacts = job.artifacts.filter((item) => item.name !== fileName);
    job.artifacts.push({ name: fileName, sha256: actual, size: buffer.length, path: file });
    job.updatedAt = new Date(this.now()).toISOString();
    this.#writeJob(job);
    return job.artifacts.find((item) => item.name === fileName);
  }

  completeJob(id, auth, { evidence, cleanupReceipt }) {
    const job = this.loadJob(id);
    this.#assertOwner(job, auth);
    if (!job.artifacts.length) throw new Error('completed job requires at least one verified artifact');
    const checked = {
      compile: proofReceipt(evidence?.compile, 'compile'),
      install: proofReceipt(evidence?.install, 'install'),
      launch: proofReceipt(evidence?.launch, 'launch'),
      parity: proofReceipt(evidence?.parity, 'parity'),
    };
    if (!cleanupReceipt || cleanupReceipt.deleted !== true || cleanupReceipt.operationNonce !== job.operationNonce) throw new Error('cleanup receipt is invalid');
    job.status = 'complete';
    job.evidence = checked;
    job.cleanupReceipt = cleanupReceipt;
    job.progress = { stage: 'complete', completed: 4, total: 4, message: 'Target build, install, launch, and parity proof complete' };
    job.finishedAt = new Date(this.now()).toISOString();
    job.updatedAt = job.finishedAt;
    return this.#writeJob(job);
  }

  cancelJob(id) {
    const job = this.loadJob(id);
    if (TERMINAL.has(job.status)) return job;
    job.status = 'cancelled';
    job.operationNonce = crypto.randomBytes(32).toString('hex');
    job.fencingToken = job.fencingToken == null ? null : job.fencingToken + 1;
    job.progress = { stage: 'cancelled', completed: 0, total: 1, message: 'Cancelled and fenced' };
    job.finishedAt = new Date(this.now()).toISOString();
    job.updatedAt = job.finishedAt;
    return this.#writeJob(job);
  }

  markHostLost(id, workerId) {
    const job = this.loadJob(id);
    if (job.status !== 'running' || job.worker?.id !== workerId) throw new Error('worker does not own this running job');
    job.invalidatedArtifacts.push(...job.artifacts.map((artifact) => ({ ...artifact, invalidatedAt: new Date(this.now()).toISOString(), reason: 'host-lost' })));
    job.artifacts = [];
    job.worker = null;
    job.fencingToken = this.#nextFence(`${job.targetPlatform}:${workerId}`);
    job.operationNonce = crypto.randomBytes(32).toString('hex');
    job.leaseExpiresAt = null;
    job.status = 'queued';
    job.progress = { stage: 'queued', completed: 0, total: 1, message: 'Worker lost; artifacts invalidated and job requeued' };
    job.updatedAt = new Date(this.now()).toISOString();
    return this.#writeJob(job);
  }
}

export class OnlineBrokerClient {
  constructor({ endpoint: brokerEndpoint, request = globalThis.fetch }) {
    this.endpoint = endpoint(brokerEndpoint);
    if (typeof request !== 'function') throw new Error('an HTTP request implementation is required');
    this.request = request;
  }

  async submit(payload) {
    const response = await this.request(`${this.endpoint}/v1/conversion-jobs`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
    });
    const body = await response.json();
    if (!response.ok) throw new Error(body.error ?? `online broker returned HTTP ${response.status}`);
    return body;
  }

  async status(jobId) {
    const response = await this.request(`${this.endpoint}/v1/conversion-jobs/${encodeURIComponent(jobId)}`);
    const body = await response.json();
    if (!response.ok) throw new Error(body.error ?? `online broker returned HTTP ${response.status}`);
    return body;
  }

  async uploadChunk(jobId, operationNonce, file) {
    const response = await this.request(`${this.endpoint}/v1/conversion-jobs/${encodeURIComponent(jobId)}/chunks/${file.index}`, {
      method: 'PUT',
      headers: {
        'Content-Type': 'application/octet-stream',
        'X-Circuit-Operation-Nonce': operationNonce,
        'X-Circuit-Path': encodeURIComponent(file.path),
        'X-Circuit-SHA256': file.sha256,
      },
      body: fs.readFileSync(file.absolutePath),
    });
    const body = await response.json();
    if (!response.ok) throw new Error(body.error ?? `online broker returned HTTP ${response.status}`);
    return body;
  }

  async cancel(jobId, operationNonce) {
    const response = await this.request(`${this.endpoint}/v1/conversion-jobs/${encodeURIComponent(jobId)}/cancel`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ operationNonce }),
    });
    const body = await response.json();
    if (!response.ok) throw new Error(body.error ?? `online broker returned HTTP ${response.status}`);
    return body;
  }
}
