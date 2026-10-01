import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync(
  "supabase/migrations/20261001203000_selectable_cash_bank_accounts.sql",
  "utf8",
);
const app=fs.readFileSync("src/AppMonolith.jsx","utf8");

test("supplier payments and customer receipts persist the selected cash/bank account",()=>{
  assert.match(migration,/alter table public\.supplier_payments[\s\S]*cash_bank_account_id uuid/i);
  assert.match(migration,/alter table public\.customer_receipts[\s\S]*cash_bank_account_id uuid/i);
  assert.match(migration,/insert into public\.supplier_payments\([\s\S]*cash_bank_account_id/i);
  assert.match(migration,/insert into public\.customer_receipts\([\s\S]*cash_bank_account_id/i);
});

test("cash integration uses selected account with legacy default fallback",()=>{
  assert.match(migration,/new\.cash_bank_account_id is null[\s\S]*default_cash_bank/i);
  assert.match(migration,/accounting_assert_cash_bank_posting_account\(new\.cash_bank_account_id\)/i);
  assert.match(migration,/get_cash_bank_posting_accounts\(\)/i);
  assert.match(migration,/account_code in \('1\.1\.01','1\.1\.02'\)/i);
});

test("supplier and customer forms require aligned settlement account selection",()=>{
  assert.match(app,/label="حساب السداد"/);
  assert.match(app,/label="حساب التحصيل"/);
  assert.match(app,/اختر حساب السداد \(بنك أو خزينة\)/);
  assert.match(app,/اختر حساب التحصيل \(بنك أو خزينة\)/);
  assert.match(app,/record_supplier_payment"[\s\S]*cash_bank_account: payload\.cashBankAccountId/);
  assert.match(app,/record_customer_receipt"[\s\S]*cash_bank_account: payload\.cashBankAccountId/);
});

test("legacy RPC names stay stable and the new account parameter remains optional",()=>{
  assert.match(migration,/create function public\.record_supplier_payment\([\s\S]*cash_bank_account uuid default null/i);
  assert.match(migration,/create function public\.record_customer_receipt\([\s\S]*cash_bank_account uuid default null/i);
});
