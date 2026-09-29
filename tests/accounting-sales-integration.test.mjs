import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929104122_accounting_sales_integration.sql",
  "utf8",
);
const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("sales integration is activation-gated and does not backfill",()=>{
  assert.match(sql,/private\.accounting_source_event_in_scope\(event_date\)/);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\.sales/i);
  assert.doesNotMatch(sql,/update\s+public\.sales/i);
});

test("posted sale charges AR and credits mapped sales revenue",()=>{
  assert.match(sql,/sale_customer_charge_posted/);
  assert.match(sql,/accounting_resolve_mapping\('accounts_receivable','global',''\)/);
  assert.match(sql,/accounting_resolve_mapping\('sales_revenue','global',''\)/);
  assert.match(sql,/'partner_type','customer'[\s\S]*'partner_id',new\.customer_id/);
  assert.match(sql,/'debit',sale_amount/);
  assert.match(sql,/'credit',sale_amount/);
});

test("sale inventory issue posts COGS against inventory using canonical movement cost",()=>{
  assert.match(sql,/new\.movement_type='sale_issue'/);
  assert.match(sql,/abs\(coalesce\(new\.quantity_delta,0\)\)\*coalesce\(new\.unit_cost,0\)/);
  assert.match(sql,/accounting_resolve_mapping\('cogs','global',''\)/);
  assert.match(sql,/accounting_resolve_mapping\('inventory','global',''\)/);
  assert.match(sql,/sale_inventory_issue_posted/);
});

test("zero-valued sale inventory issues do not create fake zero-value journals",()=>{
  assert.match(sql,/if cost_amount=0 then[\s\S]*return new/);
});

test("sales cancellation and inventory reversal are source-driven",()=>{
  assert.match(sql,/old\.status='posted'[\s\S]*new\.status='cancelled'/);
  assert.match(sql,/accounting_reverse_source_journal\([\s\S]*'sale_customer_charge_posted'/);
  assert.match(sql,/new\.movement_type='sale_issue_reversal'/);
  assert.match(sql,/new\.reversed_movement_id::text/);
  assert.match(sql,/accounting_reverse_source_journal\([\s\S]*'sale_inventory_issue_posted'/);
});

test("sales integration reuses generic source-link helpers and contains no generated account ids",()=>{
  assert.match(sql,/private\.accounting_post_source_journal/);
  assert.match(sql,/private\.accounting_reverse_source_journal/);
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("sales trigger functions are private and not directly executable by API roles",()=>{
  assert.match(sql,/revoke all on function private\.accounting_sale_charge_gl_trigger\(\)[\s\S]*from public,anon,authenticated/);
  assert.match(sql,/revoke all on function private\.accounting_sale_inventory_gl_trigger\(\)[\s\S]*from public,anon,authenticated/);
});

test("integration matrix marks both sales charge and sale inventory issue as implemented",()=>{
  assert.match(matrix,/Sales customer-charge \/ sale-inventory integration: implemented\./);
  assert.match(matrix,/Expenses, Payroll, Daily Labor, Rentals, Assets: planned/);
});
