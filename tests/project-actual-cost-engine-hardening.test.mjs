import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const sql = fs.readFileSync('supabase/migrations/202607190007_project_actual_cost_engine_hardening.sql', 'utf8');

test('accountants can view, create, and submit actual costs but cannot approve by default', () => {
  assert.match(sql, /when 'accountant'/);
  assert.match(sql, /project_actual_cost_view/);
  assert.match(sql, /project_actual_cost_create/);
  assert.match(sql, /project_actual_cost_submit/);
  assert.doesNotMatch(sql, /'project_actual_cost_approve'\s*\]/);
});

test('approved actual cost updates projects through the protected workspace gate', () => {
  assert.match(sql, /set_config\('app\.project_workspace_rpc', 'on', true\)/);
  assert.match(sql, /where c\.project_id = p\.id\s+and c\.status = 'approved'/);
});

test('milestone and budget item links must belong to the same project', () => {
  assert.match(sql, /Milestone does not belong to the selected project/);
  assert.match(sql, /Budget item does not belong to the selected project/);
  assert.match(sql, /create trigger validate_actual_cost_links/);
});

test('source reference keys cannot be blank', () => {
  assert.match(sql, /project_actual_cost_reference_key_not_blank/);
  assert.match(sql, /btrim\(source_reference_key\) <> ''/);
});
