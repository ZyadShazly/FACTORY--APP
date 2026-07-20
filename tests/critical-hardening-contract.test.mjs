import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const app = fs.readFileSync('src/App.jsx', 'utf8');

// Audit guard for the current Critical hardening sprint. This intentionally
// fails while the legacy production direct-table contract remains in App.jsx.
test('production UI no longer reads production_orders directly', () => {
  assert.doesNotMatch(app, /from\(["']production_orders["']\)/);
});

test('production UI uses a protected production workspace RPC', () => {
  assert.match(app, /get_production_workspace|list_production_orders_visible/);
});
