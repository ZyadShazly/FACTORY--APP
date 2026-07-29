import test from"node:test";
import assert from"node:assert/strict";
import{readFileSync}from"node:fs";

const migration=readFileSync("supabase/migrations/202607290003_explicit_inventory_item_type.sql","utf8");
const ui=readFileSync("src/operational/InventoryCatalogPanel.jsx","utf8");

test("inventory item type is explicit and independent from links",()=>{
  assert.match(migration,/add column if not exists item_type text/);
  assert.match(migration,/item_type in \('raw_material','finished_good'\)/);
  assert.match(migration,/material_id is null or item_type='raw_material'/);
  assert.match(migration,/product_id is null or item_type='finished_good'/);
  assert.match(migration,/create_inventory_item_typed/);
  assert.match(migration,/before insert or update of material_id,product_id,item_type,sku/);
});

test("catalog tabs and creation use explicit item type",()=>{
  assert.match(ui,/item\.item_type==="raw_material"/);
  assert.match(ui,/item\.item_type==="finished_good"/);
  assert.match(ui,/label="نوع الصنف"/);
  assert.match(ui,/value="raw_material">مادة خام/);
  assert.match(ui,/value="finished_good">منتج تام/);
  assert.match(ui,/create_inventory_item_typed/);
  assert.match(ui,/فك الربط مع الاحتفاظ بنوع الصنف كمادة خام/);
  assert.doesNotMatch(ui,/filter\(item=>!item\.material_id/);
});