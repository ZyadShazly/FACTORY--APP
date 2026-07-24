import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(
  new URL('../supabase/migrations/202607240001_procurement_request_lifecycle_history.sql', import.meta.url),
  'utf8',
);

test('purchase request lifecycle keeps converted and completed states', () => {
  assert.match(migration, /'converted','completed'/);
  assert.match(migration, /status='completed'/);
  assert.match(migration, /new\.status in \('invoiced','closed'\)/);
});

test('purchase request status changes are audit logged', () => {
  assert.match(migration, /create table if not exists public\.purchase_request_status_history/);
  assert.match(migration, /after insert or update of status on public\.purchase_requests/);
  assert.match(migration, /from_status/);
  assert.match(migration, /to_status/);
  assert.match(migration, /changed_by/);
  assert.match(migration, /changed_at/);
});

test('existing requests receive an honest baseline instead of fabricated transitions', () => {
  assert.match(migration, /event_type text not null default 'transition'/);
  assert.match(migration, /'baseline'/);
  assert.match(migration, /Current state when lifecycle history was enabled/);
});

test('procurement workspace exposes request history without direct table access', () => {
  assert.match(migration, /'request_history'/);
  assert.match(migration, /revoke all on public\.purchase_request_status_history from anon,authenticated/);
  assert.match(migration, /grant execute on function public\.get_procurement_workspace_v2\(uuid\) to authenticated/);
});
