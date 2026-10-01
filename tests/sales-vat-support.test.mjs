import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20261001184536_sales_vat_support.sql",
  "utf8",
);
const ui=fs.readFileSync("src/AppMonolith.jsx","utf8");

test("sales VAT migration adds tax fields with bounded configurable rate",()=>{
  assert.match(sql,/add column if not exists tax_rate numeric\(9,4\) not null default 0/i);
  assert.match(sql,/add column if not exists tax_amount numeric\(18,2\) not null default 0/i);
  assert.match(sql,/sales_tax_rate_valid[\s\S]*tax_rate >= 0 and tax_rate <= 100/i);
  assert.match(sql,/tax_amount = round\(\(qty \* unit_price\) \* tax_rate \/ 100, 2\)/i);
});

test("new taxed sale RPC preserves legacy post_sale compatibility",()=>{
  assert.match(sql,/create or replace function public\.post_sale_with_tax\(/i);
  assert.match(sql,/sale_tax_rate numeric default 0/i);
  assert.match(sql,/gross_total:=round\(net_total\+tax_value,2\)/i);
  assert.match(sql,/create or replace function public\.post_sale\([\s\S]*return public\.post_sale_with_tax\([\s\S]*sale_unit_price,[\s\S]*0,/i);
});

test("sales accounting splits gross AR into net revenue and VAT output",()=>{
  assert.match(sql,/accounting_resolve_mapping\('vat_output','global',''\)/);
  assert.match(sql,/'debit',gross_amount/);
  assert.match(sql,/'credit',revenue_amount/);
  assert.match(sql,/'credit',tax_amount_value/);
  assert.match(sql,/mapping_key[\s\S]*'vat_output'[\s\S]*2\.1\.07/i);
});

test("sales UI allows user-selected VAT percentage",()=>{
  assert.match(ui,/taxRate: "0"/);
  assert.match(ui,/label="ضريبة القيمة المضافة %"/);
  assert.match(ui,/min="0" max="100" step="0\.01"/);
  assert.match(ui,/supabase\.rpc\("post_sale_with_tax"/);
  assert.match(ui,/sale_tax_rate: taxRate/);
});
