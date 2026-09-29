import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929112729_accounting_expense_integration.sql",
  "utf8",
);
const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("expense integration is activation-gated and does not backfill history",()=>{
  assert.match(sql,/private\.accounting_source_event_in_scope\(event_date\)/);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\.expenses/i);
  assert.doesNotMatch(sql,/update\s+public\.expenses/i);
});

test("current gross spent-expense source posts default expense against default bank cash",()=>{
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'expense_default','global',''/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'default_cash_bank','global',''/);
  assert.match(sql,/'account_id',expense_account[\s\S]*'debit',amount_base/);
  assert.match(sql,/'account_id',bank_account[\s\S]*'credit',amount_base/);
  assert.match(sql,/expense_posted/);
});

test("expense project link flows to GL lines without double-posting project actual cost",()=>{
  assert.match(sql,/'project_id',new\.project_id/);
  assert.doesNotMatch(sql,/project_actual_cost_entries/);
  assert.doesNotMatch(sql,/actual_cost_entry_id/);
});

test("expense cancellation reverses the source-linked journal",()=>{
  assert.match(sql,/old\.cancelled_at is null[\s\S]*new\.cancelled_at is not null/);
  assert.match(sql,/accounting_reverse_source_journal\([\s\S]*'expenses'[\s\S]*'expense_posted'/);
  assert.match(sql,/new\.cancellation_reason/);
});

test("integration does not invent VAT payable supplier or payment-state semantics absent from source",()=>{
  assert.doesNotMatch(sql,/vat_input/);
  assert.doesNotMatch(sql,/accounts_payable/);
  assert.doesNotMatch(sql,/supplier_id/);
  assert.doesNotMatch(sql,/payment_method/);
});

test("expense trigger is private and the existing public expense RPC contract is untouched",()=>{
  assert.match(sql,/revoke all on function private\.accounting_expense_gl_trigger\(\)[\s\S]*from public,anon,authenticated/);
  assert.doesNotMatch(sql,/create or replace function public\.post_expense/);
  assert.doesNotMatch(sql,/create or replace function public\.cancel_expense/);
});

test("integration matrix reflects the actual expense source contract",()=>{
  assert.match(matrix,/Expense posting \(current gross spent-expense source\)/);
  assert.match(matrix,/Expense operational integration: implemented\./);
  assert.match(matrix,/Rentals, Assets: planned/);
});
