import { once } from 'node:events';
export const OWNER_KEY = 'circuit_synthetic_test_owner_key_32_bytes';
export const ownerHeaders = { Authorization: `Bearer ${OWNER_KEY}` };
export async function stopServer(child) {
  if (child.exitCode !== null) return;
  const done = once(child, 'exit');
  child.send({ type: 'circuit:shutdown' });
  const [code, signal] = await done;
  if (code !== 0 || signal) throw new Error(`Child did not exit normally: ${code}/${signal}`);
}
