import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const app=fs.readFileSync("src/AppMonolith.jsx","utf8");
const accounting=fs.readFileSync("src/accounting/AccountingWorkspace.jsx","utf8");
const journal=fs.readFileSync("src/accounting/JournalWorkspace.jsx","utf8");

test("system sales journals expose an original-transaction drilldown",()=>{
  assert.match(accounting,/onNavigate=\{onNavigate\}/);
  assert.match(journal,/row\.source_module==="sales"/);
  assert.match(journal,/فتح الحركة الأصلية/);
  assert.match(journal,/onNavigate\("sales",\{sourceRecordId:row\.source_record_id\}\)/);
});

test("sales source drilldown highlights and scrolls to the exact sale",()=>{
  assert.match(app,/focusedSaleId=\{routeSourceRecordId\}/);
  assert.match(app,/sale-source-\$\{focusedSaleId\}/);
  assert.match(app,/scrollIntoView\(\{ behavior: "smooth", block: "center" \}\)/);
  assert.match(app,/تم تحديد حركة المصدر المحاسبي المطلوبة/);
});
