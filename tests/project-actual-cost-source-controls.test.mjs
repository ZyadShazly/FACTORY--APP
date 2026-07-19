import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const sql = fs.readFileSync('supabase/migrations/202607190008_project_actual_cost_source_controls.sql', 'utf8');

test('manual adjustments are owner-only', () => {
  assert.match(sql, /Only Owner may create manual actual cost adjustments/);
  assert.match(sql, /new\.source_type = 'manual_adjustment'/);
});

test('source types are locked to canonical cost categories', () => {
  assert.match(sql, /warehouse_issue_line/);
  assert.match(sql, /factory_labor_allocation/);
  assert.match(sql, /asset_consumption_line/);
  assert.match(sql, /employee_cash_custody_settlement_line/);
  assert.match(sql, /petty_cash_settlement_line/);
});
