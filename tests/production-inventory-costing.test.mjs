import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const migration = await readFile(
  new URL("../supabase/migrations/20260922082000_fix_production_cost_material_variable.sql", import.meta.url),
  "utf8",
);

test("production-order planned material cost uses warehouse weighted-average inventory valuation", () => {
  assert.match(migration, /from public\.inventory_balances ib/);
  assert.match(migration, /ib\.inventory_item_id=item_id/);
  assert.match(migration, /ib\.warehouse_id=target_warehouse/);
  assert.match(migration, /ib\.inventory_value\/ib\.quantity_on_hand/);
  assert.match(migration, /required_qty\*coalesce\(material_unit_cost,0\)/);
});

test("production-order material costing only falls back to material master cost when no inventory average exists", () => {
  assert.match(migration, /if material_unit_cost is null then/);
  assert.match(migration, /select m\.unit_cost/);
  assert.match(migration, /where m\.id=material_id/);
});

test("production-order total and unit costs still include labor and overhead", () => {
  assert.match(migration, /set materials_cost=materials_total/);
  assert.match(migration, /coalesce\(product_row\.labor_cost,0\)\*target_quantity/);
  assert.match(migration, /coalesce\(product_row\.overhead_cost,0\)\*target_quantity/);
  assert.match(migration, /\)\/target_quantity/);
});
