// The container image (Dockerfile) copies its files by name, so a module the driver imports but the image leaves out
// stops every bot at start (`zoom-ui.mjs`, 2026-11-22: the test copy answered 502 to every new bot). Run: node --test bot/container/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const here = new URL('./', import.meta.url);
const read = (name) => fs.readFileSync(new URL(name, here), 'utf8');

// The driver and every file of this folder it imports, at any depth.
function imported(name, seen = new Set()) {
  if (seen.has(name)) return seen;
  seen.add(name);
  for (const [, file] of read(name).matchAll(/^import\s[^;]*?from\s+'\.\/([^']+)'/gm)) imported(file, seen);
  return seen;
}

test('the image copies every file the driver imports from this folder', () => {
  const copied = new Set(read('Dockerfile').split('\n').filter((line) => line.startsWith('COPY '))
    .flatMap((line) => line.split(/\s+/).slice(1).filter((word) => !word.startsWith('--'))));
  const missing = [...imported('driver.mjs')].filter((file) => !copied.has(file));
  assert.deepEqual(missing, []);
});
