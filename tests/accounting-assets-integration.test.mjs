import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929131000_accounting_assets_integration.sql",
  "utf8",
);
const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("asset registry and custody operations do not create automatic accounting",()=>{
  assert.doesNotMatch(sql,/after insert on public\.assets/);
  assert.doesNotMatch(sql,/after update on public\.assets/);
  assert.doesNotMatch(sql,/asset_assignments[\s\S]*accounting_post_source_journal/);
  assert.doesNotMatch(sql,/asset_return_events[\s\S]*accounting_post_source_journal/);
  assert.doesNotMatch(sql,/purchase_cost[\s\S]*accounting_post_source_journal/);
  assert.match(matrix,/purchase_cost.*registry metadata/);
});

test("approved valued settlement posts the exact approved estimated loss",()=>{
  assert.match(sql,/old\.status<>'approved'[\s\S]*new\.status='approved'/);
  assert.match(sql,/amount_base:=round\(coalesce\(new\.estimated_loss,0\),2\)/);
  assert.doesNotMatch(sql,/estimated_loss[^;\n]*\*[^;\n]*quantity/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'asset_loss_expense','global',''/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'asset_control','global',''/);
  assert.match(sql,/'account_id',loss_account[\s\S]*'debit',amount_base/);
  assert.match(sql,/'account_id',asset_account[\s\S]*'credit',amount_base/);
  assert.match(sql,/asset_loss_settlement_posted/);
});

test("asset settlement carries the assignment project without treating employee as a receivable",()=>{
  assert.match(sql,/assignment_row\.project_id/);
  assert.match(sql,/'project_id',assignment_row\.project_id/);
  assert.doesNotMatch(sql,/'partner_type','employee'/);
  assert.doesNotMatch(sql,/employee_receivable/i);
});

test("maintenance posts only actual completed cost",()=>{
  assert.match(sql,/old\.status='open'[\s\S]*new\.status='completed'/);
  assert.match(sql,/amount_base:=round\(coalesce\(new\.actual_cost,0\),2\)/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'asset_maintenance_expense','global',''/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'asset_maintenance_credit','global',''/);
  assert.match(sql,/'account_id',maintenance_expense_account[\s\S]*'debit',amount_base/);
  assert.match(sql,/'account_id',maintenance_credit_account[\s\S]*'credit',amount_base/);
  assert.match(sql,/asset_maintenance_cost_posted/);
  assert.doesNotMatch(sql,/estimated_cost[\s\S]*accounting_post_source_journal/);
});

test("zero-valued settlement and maintenance stay operational only",()=>{
  assert.ok((sql.match(/if amount_base=0 then/g)||[]).length>=2);
});

test("asset integration is activation-gated and contains no historical backfill",()=>{
  assert.ok((sql.match(/private\.accounting_source_event_in_scope\(event_date\)/g)||[]).length>=2);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\.asset/i);
});

test("asset mappings are configurable and do not hard-code generated account ids",()=>{
  for(const key of["asset_control","asset_loss_expense","asset_maintenance_expense","asset_maintenance_credit"]){
    assert.match(sql,new RegExp(`'${key}'`));
  }
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("asset integration does not invent post-approval or completed-maintenance reversal APIs",()=>{
  assert.doesNotMatch(sql,/create or replace function public\.reverse_asset_settlement/i);
  assert.doesNotMatch(sql,/create or replace function public\.reverse_completed_asset_maintenance/i);
  assert.match(matrix,/currently operationally immutable/);
});

test("integration matrix is complete after asset integration",()=>{
  assert.match(matrix,/Asset valued-settlement \/ maintenance integration: implemented\./);
  assert.match(matrix,/All Integration Matrix modules above now have an explicit accounting behavior/);
});
