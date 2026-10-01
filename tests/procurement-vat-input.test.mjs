import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const source=fs.readFileSync("src/operational/ProcurementWorkspace.jsx","utf8");

test("procurement quote exposes configurable VAT percentage",()=>{
  assert.match(source,/tax_rate:"0"/);
  assert.match(source,/label="ضريبة القيمة المضافة %"/);
  assert.match(source,/min="0" max="100"/);
  assert.match(source,/taxRate=Number\(quote\.tax_rate\|\|0\)/);
  assert.match(source,/taxRate<0\|\|taxRate>100/);
});

test("supplier quote tax amount is calculated from user-selected percentage",()=>{
  assert.match(
    source,
    /taxAmount=Math\.round\(\(quantity\*unitPrice\*taxRate\/100\+Number\.EPSILON\)\*100\)\/100/,
  );
  assert.match(source,/tax_amount:taxAmount/);
  assert.doesNotMatch(
    source,
    /save_supplier_quote[\s\S]{0,1200}tax_amount:0/,
  );
});
