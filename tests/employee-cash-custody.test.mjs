import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync("supabase/migrations/20261002215604_employee_cash_custody.sql","utf8");
const dateIntegrity=fs.readFileSync("supabase/migrations/20261002221138_cash_custody_date_integrity.sql","utf8");
const selectableExpense=fs.readFileSync("supabase/migrations/20261002223000_cash_custody_selectable_expense_account.sql","utf8");
const ui=fs.readFileSync("src/operational/EmployeeCashCustodyWorkspace.jsx","utf8");
const app=fs.readFileSync("src/AppMonolith.jsx","utf8");
const nav=fs.readFileSync("src/navigation.js","utf8");

test("cash custody has immutable source ledgers and idempotent commands",()=>{
  for(const table of ["employee_cash_custodies","employee_cash_custody_settlements","employee_cash_custody_returns"]){
    assert.match(migration,new RegExp("create table if not exists public\\."+table));
  }
  assert.match(migration,/command_id uuid not null unique/g);
  assert.match(migration,/on delete restrict/g);
  assert.match(migration,/Settlement exceeds remaining cash custody balance/);
  assert.match(migration,/Return exceeds remaining cash custody balance/);
});

test("advance posts employee receivable against selected bank or cash",()=>{
  assert.match(migration,/'employee_advances_receivable'/);
  assert.match(migration,/accounting_assert_cash_bank_posting_account\(new\.cash_bank_account_id\)/);
  assert.match(migration,/'custody_advance_posted'/);
  assert.match(migration,/'employee_advance'/);
});

test("settlement expenses reduce custody and project-linked settlement becomes Actual Cost",()=>{
  assert.match(migration,/'custody_settlement_posted'/);
  assert.match(migration,/'expense_default'/);
  assert.match(migration,/'employee_cash_custody_settlement_line'/);
  assert.match(migration,/'cost_category','employee_cash_custody'/);
  assert.match(migration,/submit_project_actual_cost/);
  assert.match(migration,/approve_project_actual_cost/);
});

test("cash return debits selected bank or cash and credits employee custody",()=>{
  assert.match(migration,/'custody_return_posted'/);
  assert.match(migration,/record_employee_cash_custody_return/);
  assert.match(migration,/private\.accounting_assert_cash_bank_posting_account\(cash_bank_account\)/);
});

test("workspace exposes issue settlement return with bank cash selection",()=>{
  assert.match(ui,/record_employee_cash_custody"/);
  assert.match(ui,/record_employee_cash_custody_settlement"/);
  assert.match(ui,/record_employee_cash_custody_return"/);
  assert.match(ui,/get_employee_cash_custody_workspace/);
  assert.match(ui,/حساب الصرف/);
  assert.match(ui,/حساب الاستلام/);
  assert.match(ui,/تسوية مصروف/);
  assert.match(ui,/رد نقدية/);
});

test("cash custody is mounted under finance navigation",()=>{
  assert.match(app,/EmployeeCashCustodyWorkspace/);
  assert.match(app,/activeTab === "cashCustody"/);
  assert.match(nav,/pages: \["purchases", "expenses", "cashCustody"/);
});


test("cash custody dates use local browser date and cannot predate issue",()=>{
  assert.match(ui,/getTimezoneOffset\(\)/);
  assert.match(dateIntegrity,/Settlement date cannot be before cash custody issue date/);
  assert.match(dateIntegrity,/Return date cannot be before cash custody issue date/);
  assert.match(dateIntegrity,/coalesce\(settled_on,current_date\)<custody\.issued_on/);
  assert.match(dateIntegrity,/coalesce\(returned_on,current_date\)<custody\.issued_on/);
});


test("cash custody settlement requires an explicit active posting expense account",()=>{
  assert.match(selectableExpense,/expense_account_id uuid references public\.accounting_accounts/);
  assert.match(selectableExpense,/alter column expense_account_id set not null/);
  assert.match(selectableExpense,/Selected expense account must be an active posting expense account/);
  assert.match(selectableExpense,/expense_account is null/);
  assert.match(selectableExpense,/account_type<>'expense'/);
  assert.match(selectableExpense,/'account_id',new\.expense_account_id/);
  assert.doesNotMatch(selectableExpense,/expense_account:=private\.accounting_resolve_mapping\('expense_default'/);
});

test("cash custody workspace exposes and submits the selected expense account",()=>{
  assert.match(ui,/expense_accounts:\[\]/);
  assert.match(ui,/اختر حساب المصروف/);
  assert.match(ui,/expenseAccountId/);
  assert.match(ui,/expense_account:settlement\.expenseAccountId/);
  assert.match(selectableExpense,/get_expense_posting_accounts/);
});
