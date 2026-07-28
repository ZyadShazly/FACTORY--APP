import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/202607280006_finished_goods_production_receipt.sql", "utf8");
const inventoryUi = readFileSync("src/operational/InventoryCatalogPanel.jsx", "utf8");

test("production completion posts one finished-goods inventory receipt", () => {
  assert.match(migration, /add column if not exists product_id uuid references public\.products/);
  assert.match(migration, /inventory_items_product_once_idx/);
  assert.match(migration, /add column if not exists production_order_id uuid references public\.production_orders/);
  assert.match(migration, /inventory_production_receipt_once_idx/);
  assert.match(migration, /movement_type='production_receipt'/);
  assert.match(migration, /'production_receipt',output_item,output_warehouse,saved\.qty,output_unit_cost/);
});

test("finished-goods receipt is atomic with order completion and uses actual cost", () => {
  const receiptAt = migration.indexOf("'production_receipt',output_item");
  const completionAt = migration.indexOf("set status='completed'");
  assert.ok(receiptAt > 0 && completionAt > receiptAt, "receipt must post before completion status in the same transaction");
  assert.match(migration, /sum\(abs\(m\.quantity_delta\)\*m\.unit_cost\)/);
  assert.match(migration, /actual_material_cost\+coalesce\(saved\.labor_cost,0\)\+coalesce\(saved\.overhead_cost,0\)/);
  assert.match(migration, /not exists\([\s\S]*rev\.reversed_movement_id=m\.id/);
});

test("finished products remain separate from raw materials in inventory UI", () => {
  assert.match(inventoryUi, /finishedItems=.*!item\.material_id&&!item\.material_name/);
  assert.match(inventoryUi, /المنتجات التامة/);
});
