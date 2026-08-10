import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration=readFileSync("supabase/migrations/202608103200_production_quality_output_receipt.sql","utf8");
const ui=readFileSync("src/AppMonolith.jsx","utf8");

test("finished goods receipt uses the final quality-approved output",()=>{
  assert.match(migration,/order by operation\.sequence_no desc/);
  assert.match(migration,/new\.quantity_delta:=accepted_output/);
  assert.match(migration,/new\.unit_cost:=round\(total_output_cost\/accepted_output,4\)/);
  assert.match(migration,/quality_rejected_quantity/);
  assert.match(migration,/before insert on public\.inventory_movements/);
});

test("dashboard production and sales margin use canonical inventory movements",()=>{
  assert.match(ui,/movement\.movement_type === "production_receipt"/);
  assert.match(ui,/todayProductionReceipts\.reduce/);
  assert.match(ui,/movement\.movement_type === "sale_issue"/);
  assert.match(ui,/saleIssueCosts\.get\(sale\.id\)/);
  assert.match(ui,/مجمل ربح المبيعات/);
  assert.doesNotMatch(ui,/صافي الربح التقديري/);
});
