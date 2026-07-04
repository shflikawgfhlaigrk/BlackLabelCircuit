import { helper } from './helper.js';
import { gone } from './missing.js';
import { a } from './a.js';

export function main() {
  try {
    helper();
  } catch (e) {}
  console.log('debug');
  // TODO: fix race condition
  return gone + a;
}
