import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929110122_accounting_production_integration.sql",
  "utf8",
);
const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("production integration keeps the public material-issue signature and wraps the existing core",()=>{
  assert.match(sql,/alter function public\.issue_production_material\(uuid,numeric,text\)[\s\S]*rename to issue_production_material_core/);
  assert.match(sql,/create or replace function public\.issue_production_material\([\s\S]*target_requirement uuid[\s\S]*issue_quantity numeric[\s\S]*issue_description text default null/);
  assert.match(sql,/public\.issue_production_material_core\(/);
  assert.match(sql,/grant execute on function public\.issue_production_material\(uuid,numeric,text\)[\s\S]*to authenticated/);
});

test("project-linked production material issues bypass generic project-cost GL",()=>{
  assert.match(sql,/app\.accounting_production_material_issue/);
  assert.match(sql,/drop trigger accounting_inventory_gl on public\.inventory_movements/);
  assert.match(sql,/new\.movement_type<>'project_issue'[\s\S]*current_setting\('app\.accounting_production_material_issue'/);
});

test("production material issue posts WIP against inventory once from production_material_issues",()=>{
  assert.match(sql,/after insert on public\.production_material_issues/);
  assert.match(sql,/production_material_issue_posted/);
  assert.match(sql,/accounting_resolve_mapping\('production_wip','global',''\)/);
  assert.match(sql,/accounting_resolve_mapping\('inventory','global',''\)/);
  assert.match(sql,/'account_id',wip_account[\s\S]*'debit',amount_base/);
  assert.match(sql,/'account_id',inventory_account[\s\S]*'credit',amount_base/);
});

test("production material reversal follows the linked production issue for stock and project modes",()=>{
  assert.match(sql,/new\.movement_type not in \('production_issue_reversal','project_issue_reversal'\)/);
  assert.match(sql,/issue\.inventory_movement_id=new\.reversed_movement_id/);
  assert.match(sql,/accounting_reverse_source_journal\([\s\S]*'production_material_issue_posted'/);
});

test("production completion absorbs labor and overhead into WIP at the canonical receipt",()=>{
  assert.match(sql,/new\.movement_type<>'production_receipt'/);
  assert.match(sql,/production_labor_overhead_absorbed/);
  assert.match(sql,/production_labor_clearing/);
  assert.match(sql,/production_overhead_clearing/);
  assert.match(sql,/'account_id',wip_account[\s\S]*'debit',absorption_base/);
});

test("finished-goods completion debits inventory and clears current WIP with explicit variance handling",()=>{
  assert.match(sql,/production_completion_posted/);
  assert.match(sql,/receipt_base:=round\(abs\(coalesce\(new\.quantity_delta,0\)\)\*coalesce\(new\.unit_cost,0\),2\)/);
  assert.match(sql,/material_wip_base[\s\S]*accounting_source_links/);
  assert.match(sql,/variance_base:=round\(receipt_base-expected_wip_base,2\)/);
  assert.match(sql,/production_cost_variance/);
  assert.match(sql,/'account_id',inventory_account[\s\S]*'debit',receipt_base/);
  assert.match(sql,/'account_id',wip_account[\s\S]*'credit',expected_wip_base/);
});

test("production mappings remain configurable and contain no generated account ids",()=>{
  for(const key of["production_labor_clearing","production_overhead_clearing","production_cost_variance"]){
    assert.match(sql,new RegExp(`'${key}'`));
  }
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("production integration is activation-gated and has no historical backfill",()=>{
  assert.match(sql,/private\.accounting_source_event_in_scope\(event_date\)/);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\.production_/i);
});

test("completed production correction is documented as source-immutable rather than inventing a reversal API",()=>{
  assert.doesNotMatch(sql,/create or replace function public\.reverse_completed_production/i);
  assert.match(matrix,/currently operationally immutable after completion/);
});

test("integration matrix marks production implemented and leaves later modules planned",()=>{
  assert.match(matrix,/Production material-issue \/ completion integration: implemented\./);
  assert.match(matrix,/Expenses, Payroll, Daily Labor, Rentals, Assets: planned/);
});
