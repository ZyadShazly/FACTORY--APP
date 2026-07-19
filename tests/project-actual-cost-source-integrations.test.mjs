import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration = fs.readFileSync(
  new URL('../supabase/migrations/202607190010_project_actual_cost_source_integrations.sql', import.meta.url),
  'utf8',
);
const hardening = fs.readFileSync(
  new URL('../supabase/migrations/202607190011_project_actual_cost_source_status_hardening.sql', import.meta.url),
  'utf8',
);

test('operational sources post through protected Actual Cost workflow', () => {
  for (const source of ['material_purchase', 'daily_labor', 'payroll_allocation', 'approved_expense']) {
    assert.match(migration, new RegExp(`'${source}'`));
  }
  assert.match(migration, /prepare_operational_source_actual_cost/);
  assert.match(migration, /approve_operational_source_actual_cost/);
  assert.match(migration, /reject_operational_source_actual_cost/);
  assert.match(migration, /actual_cost_assert_mutable/);
  assert.match(migration, /Source is already linked to an Actual Cost entry/);
});

test('source state follows generic approval, rejection and reversal paths', () => {
  assert.match(hardening, /after insert or update of status/);
  assert.match(hardening, /when 'approved' then 'posted'/);
  assert.match(hardening, /when 'rejected' then 'rejected'/);
  assert.match(hardening, /when 'reversed' then 'reversed'/);
  assert.match(hardening, /revoke all on function private\.sync_operational_source_actual_cost_status\(\) from public,anon,authenticated/);
});

test('integration RPCs are not executable anonymously', () => {
  assert.match(migration, /revoke all on function public\.prepare_operational_source_actual_cost\(text,uuid\) from public,anon/);
  assert.match(migration, /revoke all on function public\.approve_operational_source_actual_cost\(uuid\) from public,anon/);
  assert.match(migration, /revoke all on function public\.reject_operational_source_actual_cost\(uuid,text\) from public,anon/);
});
