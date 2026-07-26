import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const css = await readFile(new URL('../src/operational/procurementPrint.css', import.meta.url), 'utf8');

test('procurement status board uses a balanced responsive grid', () => {
  assert.match(css, /section\[data-request-stage\]/);
  assert.match(css, /repeat\(3,\s*minmax\(0,\s*1fr\)\)/);
  assert.match(css, /max-width:\s*1100px/);
  assert.match(css, /repeat\(2,\s*minmax\(0,\s*1fr\)\)/);
  assert.match(css, /max-width:\s*720px/);
  assert.match(css, /grid-template-columns:\s*minmax\(0,\s*1fr\)/);
});
