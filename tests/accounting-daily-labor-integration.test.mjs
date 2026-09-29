import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929124500_accounting_daily_labor_integration.sql",
  "utf8",
);
const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("daily labor integration posts only on approval, not draft creation",()=>{
  assert.match(sql,/old\.review_status='draft'[\s\S]*new\.review_status='approved'/);
  assert.doesNotMatch(sql,/after insert on public\.daily_labor/);
  assert.match(matrix,/review_daily_labor/);
});

test("daily labor accrual is activation-gated and uses work date",()=>{
  assert.match(sql,/accrual_date date:=coalesce\(new\.work_date,current_date\)/);
  assert.match(sql,/private\.accounting_source_event_in_scope\(accrual_date\)/);
});

test("approved daily labor debits gross labor expense and credits net payable plus deductions clearing",()=>{
  assert.match(sql,/gross_base:=round\(net_base\+deduction_base,2\)/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'daily_labor_expense','global',''/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'daily_labor_payable','global',''/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'daily_labor_deductions_clearing','global',''/);
  assert.match(sql,/'account_id',labor_expense_account[\s\S]*'debit',gross_base/);
  assert.match(sql,/'account_id',labor_payable_account[\s\S]*'credit',net_base/);
  assert.match(sql,/'account_id',deduction_account[\s\S]*'credit',deduction_base/);
});

test("daily labor accrual carries project traceability and does not double-post actual cost",()=>{
  assert.match(sql,/'project_id',new\.project_id/);
  assert.match(sql,/daily_labor_accrual_posted/);
  assert.doesNotMatch(sql,/project_actual_cost_entries/);
  assert.doesNotMatch(sql,/actual_cost_entry_id/);
});

test("daily labor payment requires an active accrual link before paying GL",()=>{
  assert.match(sql,/new\.payment_status='paid'/);
  assert.match(sql,/source_event\)\)='daily_labor_accrual_posted'/);
  assert.match(sql,/l\.link_status='active'/);
  assert.match(sql,/daily_labor_payment_posted/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'default_cash_bank','global',''/);
  assert.match(sql,/'account_id',labor_payable_account[\s\S]*'debit',net_base/);
  assert.match(sql,/'account_id',bank_account[\s\S]*'credit',net_base/);
});

test("daily labor deduction mapping is configurable and no account UUID is hard-coded",()=>{
  assert.match(sql,/'daily_labor_deductions_clearing'/);
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("daily labor integration does not invent approved or paid reversal APIs",()=>{
  assert.doesNotMatch(sql,/create or replace function public\.reverse_daily_labor/i);
  assert.doesNotMatch(sql,/create or replace function public\.reverse_daily_labor_payment/i);
  assert.match(matrix,/approved\/paid shifts are currently operationally immutable/);
});

test("daily labor integration has no historical backfill and later modules stay planned",()=>{
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\.daily_labor/i);
  assert.match(matrix,/Daily Labor approval\/payment integration: implemented\./);
  assert.match(matrix,/Rentals, Assets: planned/);
});
