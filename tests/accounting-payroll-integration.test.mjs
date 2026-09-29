import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929123034_accounting_payroll_integration.sql",
  "utf8",
);
const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("payroll integration is approval-driven and never posts drafts",()=>{
  assert.match(sql,/old\.status in \('draft','rejected'\)[\s\S]*new\.status='approved'/);
  assert.doesNotMatch(sql,/after insert on public\.payroll/);
  assert.match(matrix,/never at draft creation/);
});

test("payroll accrual is activation-safe and stays inside the payroll month",()=>{
  assert.match(sql,/greatest\([\s\S]*new\.payroll_month[\s\S]*least\([\s\S]*new\.approved_at::date/);
  assert.match(sql,/private\.accounting_source_event_in_scope\(accrual_date\)/);
});

test("approved payroll debits gross payroll expense and credits net payable deductions and advance recovery",()=>{
  assert.match(sql,/gross_base:=round\(net_base\+deduction_base\+advance_base,2\)/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'payroll_expense','global',''/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'payroll_payable','global',''/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'employee_advances_receivable','global',''/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'payroll_deductions_clearing','global',''/);
  assert.match(sql,/'account_id',payroll_expense_account[\s\S]*'debit',gross_base/);
  assert.match(sql,/'account_id',payroll_payable_account[\s\S]*'credit',net_base/);
  assert.match(sql,/'account_id',employee_advance_account[\s\S]*'credit',advance_base/);
  assert.match(sql,/'account_id',deduction_account[\s\S]*'credit',deduction_base/);
});

test("payroll accrual preserves employee and project traceability",()=>{
  assert.match(sql,/'partner_type','employee'/);
  assert.match(sql,/'partner_id',new\.employee_id/);
  assert.match(sql,/'project_id',new\.project_id/);
  assert.match(sql,/payroll_accrual_posted/);
});

test("payroll payment only posts for payroll with an existing active accrual link",()=>{
  assert.match(sql,/old\.status='approved'[\s\S]*new\.status='paid'/);
  assert.match(sql,/source_event\)\)='payroll_accrual_posted'/);
  assert.match(sql,/l\.link_status='active'/);
  assert.match(sql,/payroll_payment_posted/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'default_cash_bank','global',''/);
  assert.match(sql,/'account_id',payroll_payable_account[\s\S]*'debit',net_base/);
  assert.match(sql,/'account_id',bank_account[\s\S]*'credit',net_base/);
});

test("payroll mappings are configurable and do not hard-code generated account ids",()=>{
  assert.match(sql,/'employee_advances_receivable'/);
  assert.match(sql,/'payroll_deductions_clearing'/);
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("payroll integration does not invent approved or paid reversal workflows",()=>{
  assert.doesNotMatch(sql,/create or replace function public\.reverse_payroll/i);
  assert.doesNotMatch(sql,/create or replace function public\.reverse_payroll_payment/i);
  assert.match(matrix,/currently operationally immutable/);
});

test("payroll integration has no historical backfill and leaves later modules planned",()=>{
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\.payroll/i);
  assert.match(matrix,/Payroll approval\/payment integration: implemented\./);
  assert.match(matrix,/All Integration Matrix modules above now have an explicit accounting behavior/);
});
