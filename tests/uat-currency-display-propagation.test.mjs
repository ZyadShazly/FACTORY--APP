import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { formatDocumentMoney } from "../src/userExperience.js";

const ui=fs.readFileSync("src/operational/ProcurementWorkspace.jsx","utf8");
const migration=fs.readFileSync("supabase/migrations/20260810142000_uat_procurement_currency_propagation.sql","utf8");

test("UAT-006 preview, cards and print use document currency",()=>{
  assert.match(formatDocumentMoney(100,"SAR"),/SAR/);
  assert.match(ui,/const documentCurrency=\(row\.currency\|\|order\?\.currency/);
  assert.match(ui,/documentMoney\(item\.unit_price\)/);
  assert.match(ui,/formatDocumentMoney\(row\.total_amount,row\.currency\)/);
  assert.doesNotMatch(ui,/formatMoney\(item\.unit_price\)/);
});

test("quote to PO preserves a complete positive conversion contract",()=>{
  assert.match(migration,/insert into public\.supplier_quotes[\s\S]*base_currency,exchange_rate,rate_date/);
  assert.match(migration,/base_total_amount=round\(quote_total\*rate,2\)/);
  assert.match(migration,/q\.currency,q\.base_currency,q\.exchange_rate,q\.rate_date/);
  assert.match(migration,/currency_contract_preserved',true/);
  assert.match(migration,/rate is null or rate<=0/);
});
