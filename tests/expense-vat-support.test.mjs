import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20261001185522_expense_vat_support.sql",
  "utf8",
);
const ui=fs.readFileSync("src/AppMonolith.jsx","utf8");

test("expense VAT stores net, tax rate, tax amount and gross consistently",()=>{
  assert.match(sql,/add column if not exists tax_rate numeric\(9,4\) not null default 0/i);
  assert.match(sql,/add column if not exists tax_amount numeric\(18,2\) not null default 0/i);
  assert.match(sql,/add column if not exists net_amount numeric\(18,2\)[\s\S]*amount-coalesce\(tax_amount,0\)/i);
  assert.match(sql,/tax_amount=round\(net_amount\*tax_rate\/100,2\)/i);
});

test("expense posting remains backward compatible while taxed RPC is available",()=>{
  assert.match(sql,/create or replace function public\.post_expense_with_tax\(/i);
  assert.match(sql,/expense_tax_rate numeric default 0/i);
  assert.match(sql,/gross_value:=round\(net_value\+tax_value,2\)/i);
  assert.match(sql,/create or replace function public\.post_expense\([\s\S]*post_expense_with_tax\([\s\S]*expense_amount,[\s\S]*0,/i);
});

test("expense accounting splits net expense and VAT input against gross bank payment",()=>{
  assert.match(sql,/accounting_resolve_mapping\('expense_default','global',''\)/);
  assert.match(sql,/accounting_resolve_mapping\('vat_input','global',''\)/);
  assert.match(sql,/accounting_resolve_mapping\('default_cash_bank','global',''\)/);
  assert.match(sql,/'debit',net_base/);
  assert.match(sql,/'debit',tax_base/);
  assert.match(sql,/'credit',gross_base/);
});

test("expense UI lets the user choose VAT percentage",()=>{
  assert.match(ui,/taxRate: "0"/);
  assert.match(ui,/label="ضريبة القيمة المضافة %"/);
  assert.match(ui,/min="0" max="100" step="0\.01"/);
  assert.match(ui,/supabase\.rpc\("post_expense_with_tax"/);
  assert.match(ui,/expense_tax_rate: taxRate/);
});
