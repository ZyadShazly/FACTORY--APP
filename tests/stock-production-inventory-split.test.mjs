import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const inventory=fs.readFileSync("src/operational/InventoryCatalogPanel.jsx","utf8");
const migration=fs.readFileSync("supabase/migrations/202607280005_stock_production_and_inventory_split.sql","utf8");

test("inventory separates raw materials and finished goods",()=>{
  assert.match(inventory,/stockKind/);
  assert.match(inventory,/المواد الخام/);
  assert.match(inventory,/المنتجات التامة/);
  assert.match(inventory,/item\.item_type==="raw_material"/);
  assert.match(inventory,/item\.item_type==="finished_good"/);
});

test("stock production can release without a project",()=>{
  assert.doesNotMatch(migration,/Production order must be linked to a project/);
  assert.match(migration,/production_mode.*stock/s);
  assert.match(migration,/create or replace function public\.release_production_order/);
});

test("stock production material issue posts a reversible inventory movement",()=>{
  assert.match(migration,/'production_issue'/);
  assert.match(migration,/'production_issue_reversal'/);
  assert.match(migration,/create or replace function public\.reverse_inventory_movement/);
  assert.match(migration,/req\.project_id is not null/);
});