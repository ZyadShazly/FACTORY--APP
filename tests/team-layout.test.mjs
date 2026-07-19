import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const css = fs.readFileSync('src/team-layout.css', 'utf8');
const main = fs.readFileSync('src/main.jsx', 'utf8');

test('team cards remain full-width blocks with horizontal text', () => {
  assert.match(css, /\.team-card\s*\{[\s\S]*display:\s*block\s*!important/);
  assert.match(css, /writing-mode:\s*horizontal-tb\s*!important/);
  assert.match(css, /grid-template-columns:\s*minmax\(0,\s*1fr\)\s*!important/);
});

test('team layout hardening loads after shared styles', () => {
  const shared = main.indexOf('"./styles.css"');
  const team = main.indexOf('"./team-layout.css"');
  assert.ok(shared >= 0 && team > shared);
});
