import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync("supabase/migrations/20260929065411_accounting_mapping_core.sql","utf8");

test("mapping definitions catalog is additive and typed",()=>{
  assert.match(sql,/create table public\.accounting_mapping_definitions/);
  assert.match(sql,/expected_account_types text\[\] not null/);
  assert.match(sql,/required_for_auto_posting boolean not null default true/);
  assert.match(sql,/suggested_account_code text/);
  assert.doesNotMatch(sql,/drop\s+table/i);
});

test("mapping catalog covers the first accounting integration boundaries",()=>{
  for(const key of[
    "default_cash_bank","accounts_receivable","customer_advances","sales_revenue","cogs",
    "accounts_payable","supplier_advances","inventory","grni","vat_input",
    "expense_default","payroll_expense","payroll_payable","daily_labor_expense",
    "daily_labor_payable","production_wip","current_year_profit_loss",
  ]) assert.match(sql,new RegExp(`'${key}'`));
});

test("mapping resolver uses active configurable mappings and never hard-coded account ids",()=>{
  assert.match(sql,/create or replace function private\.accounting_resolve_mapping/);
  assert.match(sql,/m\.account_id/);
  assert.match(sql,/a\.is_active/);
  assert.match(sql,/a\.is_posting/);
  assert.match(sql,/Accounting mapping is missing or unavailable/);
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("owner mapping mutation validates posting account and expected account type",()=>{
  assert.match(sql,/public\.current_identity_role\(\)<>'owner'/);
  assert.match(sql,/not account_row\.is_active or not account_row\.is_posting/);
  assert.match(sql,/account_row\.account_type=any\(definition_row\.expected_account_types\)/);
  assert.match(sql,/accounting_mapping_set/);
  assert.match(sql,/accounting_mapping_cleared/);
  assert.match(sql,/Mapping clear reason is required/);
});

test("mapping workspace returns configuration and per-module readiness",()=>{
  assert.match(sql,/create or replace function public\.get_accounting_mapping_workspace\(\)/);
  assert.match(sql,/auto_posting_readiness/);
  assert.match(sql,/'configured'/);
  assert.match(sql,/'suggested_account'/);
  assert.match(sql,/accounting_reports_view|accounting_view/);
});

test("mapping API is authenticated-only and definition table is not directly exposed",()=>{
  assert.match(sql,/alter table public\.accounting_mapping_definitions enable row level security/);
  assert.match(sql,/revoke all on table public\.accounting_mapping_definitions from anon,authenticated/);
  for(const fn of[
    "get_accounting_mapping_workspace\\(\\)",
    "owner_set_accounting_mapping\\(text,uuid\\)",
    "owner_clear_accounting_mapping\\(text,text\\)",
  ]){
    assert.match(sql,new RegExp(`revoke all on function public\\.${fn} from public,anon`));
    assert.match(sql,new RegExp(`grant execute on function public\\.${fn} to authenticated`));
  }
});

test("mapping migration does not alter operational modules or auto-post anything",()=>{
  assert.doesNotMatch(sql,/alter\s+table\s+public\.(sales|expenses|supplier_invoices|supplier_payments|customer_receipts|inventory_movements|projects|payroll|daily_labor)/i);
  assert.doesNotMatch(sql,/(insert|update|delete)\s+(into\s+|from\s+)?public\.(sales|expenses|supplier_invoices|supplier_payments|customer_receipts|inventory_movements|projects|payroll|daily_labor)/i);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries/i);
});
