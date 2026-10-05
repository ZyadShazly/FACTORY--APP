import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync(
  "supabase/migrations/20261002211416_expense_selectable_cash_bank.sql",
  "utf8",
);
const app=fs.readFileSync("src/AppMonolith.jsx","utf8");

test("expenses persist the user-selected cash or bank account",()=>{
  assert.match(migration,/alter table public\.expenses[\s\S]*cash_bank_account_id uuid/i);
  assert.match(migration,/insert into public\.expenses\([\s\S]*cash_bank_account_id/i);
  assert.match(migration,/cash_bank_account uuid default null/i);
});

test("expense accounting uses selected account with legacy default fallback",()=>{
  assert.match(migration,/new\.cash_bank_account_id is null[\s\S]*default_cash_bank/i);
  assert.match(migration,/accounting_assert_cash_bank_posting_account\(new\.cash_bank_account_id\)/i);
});

test("expense UI requires the same bank cash selection pattern as suppliers and customers",()=>{
  const section=app.slice(app.indexOf("function ExpensesTab"),app.indexOf("/* ---------------------------------- Reports"));
  assert.match(section,/label="حساب السداد"/);
  assert.match(section,/اختر البنك أو الخزينة/);
  assert.match(section,/اختر حساب السداد \(بنك أو خزينة\)/);
  assert.match(section,/get_cash_bank_posting_accounts/);
  assert.match(section,/cash_bank_account: form\.cashBankAccountId/);
});

test("legacy expense callers remain compatible",()=>{
  assert.match(migration,/cash_bank_account uuid default null/i);
  assert.match(migration,/drop function if exists public\.post_expense_with_tax\(text,numeric,numeric,date,text,uuid,uuid\)/i);
});
