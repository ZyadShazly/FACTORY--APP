import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929104901_accounting_inventory_integration.sql",
  "utf8",
);
const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("inventory integration is activation-gated and contains no historical backfill",()=>{
  assert.match(sql,/private\.accounting_source_event_in_scope\(event_date\)/);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\.inventory_movements/i);
  assert.doesNotMatch(sql,/update\s+public\.inventory_movements/i);
});

test("direct project issue debits configurable project material cost and credits inventory",()=>{
  assert.match(sql,/new\.movement_type='project_issue'/);
  assert.match(sql,/accounting_resolve_mapping\('project_material_cost','global',''\)/);
  assert.match(sql,/accounting_resolve_mapping\('inventory','global',''\)/);
  assert.match(sql,/project_inventory_issue_posted/);
  assert.match(sql,/'project_id',new\.project_id/);
});

test("project issue reversal follows the original source-linked journal",()=>{
  assert.match(sql,/new\.movement_type='project_issue_reversal'/);
  assert.match(sql,/new\.reversed_movement_id::text/);
  assert.match(sql,/accounting_reverse_source_journal\([\s\S]*'project_inventory_issue_posted'/);
});

test("positive inventory adjustment posts inventory against mapped gain",()=>{
  assert.match(sql,/new\.movement_type in \('adjustment_in','adjustment_out'\)/);
  assert.match(sql,/accounting_resolve_mapping\('inventory_adjustment_gain','global',''\)/);
  assert.match(sql,/inventory_adjustment_in_posted/);
  assert.match(sql,/'account_id',inventory_account[\s\S]*'debit',amount_base/);
  assert.match(sql,/'account_id',adjustment_gain_account[\s\S]*'credit',amount_base/);
});

test("negative inventory adjustment posts mapped loss against inventory",()=>{
  assert.match(sql,/accounting_resolve_mapping\('inventory_adjustment_loss','global',''\)/);
  assert.match(sql,/inventory_adjustment_out_posted/);
  assert.match(sql,/'account_id',adjustment_loss_account[\s\S]*'debit',amount_base/);
  assert.match(sql,/'account_id',inventory_account[\s\S]*'credit',amount_base/);
});

test("count adjustments reuse the canonical adjust_inventory source instead of a second GL path",()=>{
  assert.doesNotMatch(sql,/inventory_count_sessions/);
  assert.doesNotMatch(sql,/inventory_count_lines/);
  assert.equal((sql.match(/after insert on public\.inventory_movements/g)||[]).length,1);
});

test("inventory transfers and production movements are intentionally not posted by this integration",()=>{
  assert.doesNotMatch(sql,/new\.movement_type='transfer_in'/);
  assert.doesNotMatch(sql,/new\.movement_type='transfer_out'/);
  assert.doesNotMatch(sql,/new\.movement_type='production_issue'/);
  assert.doesNotMatch(sql,/new\.movement_type='production_receipt'/);
  assert.match(sql,/Production movements are intentionally ignored here/);
});

test("zero-value inventory movements do not create zero-value journals",()=>{
  assert.match(sql,/if amount_base=0 then[\s\S]*return new/);
});

test("inventory mapping definitions are configurable and contain no generated account ids",()=>{
  for(const key of["project_material_cost","inventory_adjustment_gain","inventory_adjustment_loss"]){
    assert.match(sql,new RegExp(`'${key}'`));
  }
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("inventory integration matrix separates project issues from production issues",()=>{
  assert.match(matrix,/Inventory \| Project material issue \(non-production\)/);
  assert.match(matrix,/Inventory project-issue \/ adjustment integration: implemented\./);
  assert.match(matrix,/Assets: planned/);
});
