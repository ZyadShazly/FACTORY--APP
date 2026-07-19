import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const sql = fs.readFileSync('supabase/migrations/202607190009_project_actual_cost_workflow_variance.sql','utf8');

test('submitted costs can be rejected only with a reason', () => {
  assert.match(sql,/reject_project_actual_cost/);
  assert.match(sql,/Rejection reason is required/);
  assert.match(sql,/Only submitted cost may be rejected/);
});

test('approved costs reverse through owner-only workflow and recalculate project actual cost', () => {
  assert.match(sql,/reverse_project_actual_cost/);
  assert.match(sql,/current_identity_role\(\) <> 'owner'/);
  assert.match(sql,/where c\.project_id=p\.id and c\.status='approved'/);
  assert.match(sql,/app\.project_workspace_rpc/);
});

test('variance snapshot uses approved estimated budget and normalized actual categories', () => {
  assert.match(sql,/get_project_cost_variance_snapshot/);
  assert.match(sql,/expected_total_cost/);
  assert.match(sql,/total_with_waste/);
  assert.match(sql,/forecast_final_cost/);
  assert.match(sql,/gross_margin_percentage/);
});

test('new workflow RPCs are not callable anonymously', () => {
  assert.match(sql,/revoke all on function public\.reject_project_actual_cost\(uuid,text\) from public,anon/);
  assert.match(sql,/revoke all on function public\.reverse_project_actual_cost\(uuid,text\) from public,anon/);
  assert.match(sql,/grant execute on function public\.get_project_cost_variance_snapshot\(uuid\) to authenticated/);
});
