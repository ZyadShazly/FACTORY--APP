import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(
  new URL('../supabase/migrations/202607240001_procurement_request_lifecycle.sql', import.meta.url),
  'utf8',
);

test('purchase requests keep the complete operational lifecycle', () => {
  for (const status of ['draft','submitted','approved','converted','completed','rejected']) {
    assert.match(migration, new RegExp(`'${status}'`));
  }
});

test('creating a purchase order preserves the request and records conversion', () => {
  assert.match(migration, /purchase_request_status_history/);
  assert.match(migration, /record_purchase_request_status_change/);
  assert.doesNotMatch(migration, /delete\s+from\s+public\.purchase_requests/i);
});

test('request completion follows the purchase order lifecycle', () => {
  assert.match(migration, /complete_purchase_request_from_order/);
  assert.match(migration, /new\.status in \('invoiced','closed'\)/);
  assert.match(migration, /set status='completed'/);
});

test('workspace returns request history for audit and UI review', () => {
  assert.match(migration, /'request_history'/);
  assert.match(migration, /get_procurement_workspace_v2/);
});

test('migration is additive and preserves existing procurement records', () => {
  assert.match(migration, /add column if not exists converted_at/);
  assert.match(migration, /add column if not exists completed_at/);
  assert.match(migration, /jsonb_build_object\('source','backfill'\)/);
});
