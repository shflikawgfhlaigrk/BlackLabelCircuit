import { test } from 'node:test'
import assert from 'node:assert'
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// `npm test` runs an explicit file list, not a glob: a test file added to test/
// is silently never executed, and the suite still reports green. This guard
// fails that case instead of hiding it.
const here = dirname(fileURLToPath(import.meta.url))
const pkg = JSON.parse(readFileSync(join(here, '..', 'package.json'), 'utf8'))

const onDisk = readdirSync(here)
  .filter((f) => f.endsWith('.test.js'))
  .sort()

const inScript = [...pkg.scripts.test.matchAll(/test\/([\w.-]+\.test\.js)/g)]
  .map((m) => m[1])
  .sort()

test('every test file on disk is run by npm test', () => {
  const orphans = onDisk.filter((f) => !inScript.includes(f))
  assert.deepEqual(
    orphans,
    [],
    `test file(s) exist but are never run — add them to package.json scripts.test: ${orphans.join(', ')}`
  )
})

test('every test file named in npm test exists on disk', () => {
  const missing = inScript.filter((f) => !onDisk.includes(f))
  assert.deepEqual(
    missing,
    [],
    `package.json scripts.test names test file(s) that do not exist: ${missing.join(', ')}`
  )
})
