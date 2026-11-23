import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const sql = fs.readFileSync('supabase/migrations/20260719124029_project_actual_cost_engine.sql','utf8');

test('actual cost sources are canonical and deduplicated', () => {
  assert.match(sql,/project_actual_cost_source_revision_uidx/);
  assert.match(sql,/source_reference_key/);
  assert.match(sql,/where status <> 'reversed'/);
});

test('approved costs are RPC-only and direct table access is blocked', () => {
  assert.match(sql,/revoke all on public\.project_actual_cost_entries from public, anon, authenticated/);
  assert.match(sql,/grant execute on function public\.approve_project_actual_cost\(uuid\) to authenticated/);
});

test('cost freeze blocks historical mutation', () => {
  assert.match(sql,/project_cost_freezes/);
  assert.match(sql,/Actual cost period is frozen/);
});

test('project actual cost is updated from approved entries only', () => {
  assert.match(sql,/where c\.project_id=p\.id and c\.status='approved'/);
});

test('allocations must equal source amount before approval', () => {
  assert.match(sql,/Allocations must equal the source amount/);
});

test('project actual cost screen supports safe manual draft entry without direct table writes', () => {
  const ui = fs.readFileSync('src/v22/projectActualCost.jsx','utf8');
  assert.match(ui,/save_project_actual_cost/);
  assert.match(ui,/source_type: "manual_adjustment"/);
  assert.match(ui,/source_reference_key: `manual-cost:/);
  assert.match(ui,/saveManualEntry/);
  assert.match(ui,/تم حفظ التكلفة كمسودة/);
  assert.doesNotMatch(ui,/from\(["']project_actual_cost_entries["']\)\.insert/);
});
