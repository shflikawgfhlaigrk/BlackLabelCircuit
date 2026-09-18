import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Input must be a fresh, read-only capture of the currently deployed channel
// Worker. Only the new exact native-update path changes; its existing browser
// download, current-release selection and R2 pin checks stay authoritative.
export function addNativeUpdateRoute(source) {
  assert.ok(!source.includes('createNativeUpdateHandler'), 'Worker already has native update delivery');
  for (const symbol of ['function currentRelease(', 'function pinnedBucket(',
    'function servePrivateDmgGet(', 'async function handle(']) {
    assert.ok(source.includes(symbol), `Current Worker contract changed: ${symbol}`);
  }
  const marker = '  if (!["GET", "HEAD"].includes(request.method)) return new Response("Method not allowed", { status: 405, headers: { ...headers, allow: "GET, HEAD" } });';
  assert.equal(source.split(marker).length, 2, 'Expected exactly one channel method guard');
  const route = `  if (url.pathname === "/api/ace/update") {
    return createNativeUpdateHandler({
      currentRelease: () => currentRelease(data),
      deliver: async (release, bindings) => {
        if (!bindings.ACE_RELEASES || !release.r2HttpEtag) {
          return new Response(null, {status:503});
        }
        return servePrivateDmgGet({
          request: new Request("https://ace-bl.tech/dl/mac"),
          env: {ACE_RELEASES:pinnedBucket(bindings.ACE_RELEASES,release)}
        }, {...release,filename:"ace.dmg"});
      }
    })(request, env);
  }
`;
  return 'import { createNativeUpdateHandler } from "./native-update.mjs";\n'
    + source.replace(marker, route + marker);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [sourceFile, destinationDirectory] = process.argv.slice(2);
  assert.ok(sourceFile && destinationDirectory, 'Usage: node prepare-worker.mjs CURRENT_WORKER.js NEW_DIRECTORY');
  const transformed = addNativeUpdateRoute(await fs.readFile(sourceFile, 'utf8'));
  await fs.mkdir(destinationDirectory, { recursive: true });
  await fs.writeFile(path.join(destinationDirectory, 'index.js'), transformed, { flag: 'wx' });
  await fs.copyFile(new URL('./native-update.mjs', import.meta.url),
    path.join(destinationDirectory, 'native-update.mjs'), fs.constants.COPYFILE_EXCL);
  console.log('Prepared native-update Worker modules. No upload, activation or route change performed.');
}
