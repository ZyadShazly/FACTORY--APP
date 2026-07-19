import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const ui = fs.readFileSync('src/v22/projectActualCost.jsx','utf8');
const css = fs.readFileSync('src/v22/projectActualCost.css','utf8');

test('actual cost workspace loads protected snapshots', () => {
  assert.match(ui,/get_project_actual_cost_snapshot/);
  assert.match(ui,/get_project_cost_variance_snapshot/);
});

test('workflow actions are exposed by state and role', () => {
  assert.match(ui,/submit_project_actual_cost/);
  assert.match(ui,/approve_project_actual_cost/);
  assert.match(ui,/reject_project_actual_cost/);
  assert.match(ui,/reverse_project_actual_cost/);
  assert.match(ui,/profile\?\.role === "owner"/);
});

test('workspace reports variance profit forecast and source contracts', () => {
  assert.match(ui,/forecast_final_cost/);
  assert.match(ui,/gross_margin_percentage/);
  assert.match(ui,/source_reference_key/);
  assert.match(ui,/العهدة النقدية/);
});

test('workspace remains responsive on tablet and mobile', () => {
  assert.match(css,/@media\(max-width:1050px\)/);
  assert.match(css,/@media\(max-width:760px\)/);
  assert.match(css,/overflow:auto/);
});
