import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration = fs.readFileSync(
  new URL('../supabase/migrations/202608020003_expense_financial_lifecycle.sql', import.meta.url),
  'utf8',
);
const ui = fs.readFileSync(new URL('../src/AppMonolith.jsx', import.meta.url), 'utf8');

test('expense history is cancelled or reversed instead of deleted', () => {
  assert.match(migration, /before update or delete on public\.expenses/);
  assert.match(migration, /Expense history cannot be deleted; use cancel_expense/);
  assert.match(migration, /perform public\.reverse_project_actual_cost/);
  assert.match(migration, /perform public\.reject_project_actual_cost/);
  assert.match(migration, /Cancellation reason is required/);
  assert.match(migration, /expenses_cancelled_by_idx/);
});

test('expense policies require an active finance role without permissive ALL bypass', () => {
  assert.match(migration, /drop policy if exists active_profile_restriction on public\.expenses/);
  assert.match(migration, /as restrictive[\s\S]*for all to authenticated/);
  assert.match(migration, /drop policy if exists expenses_delete_manager/);
});

test('expense RPC is not anonymously executable', () => {
  assert.match(migration, /revoke all on function public\.cancel_expense\(uuid,text\)[\s\S]*from public,anon,authenticated/);
  assert.match(migration, /grant execute on function public\.cancel_expense\(uuid,text\) to authenticated/);
});

test('expense UI captures project and exposes protected financial actions', () => {
  assert.match(ui, /project_id: form\.projectId \|\| null/);
  assert.match(ui, /prepare_operational_source_actual_cost/);
  assert.match(ui, /cancel_expense/);
  assert.match(ui, /اختياري للمصروف العام/);
  assert.doesNotMatch(ui, /deleteRow\("expenses"/);
});
