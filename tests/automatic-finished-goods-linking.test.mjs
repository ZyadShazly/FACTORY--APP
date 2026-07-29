import test from"node:test";
import assert from"node:assert/strict";
import{readFileSync}from"node:fs";

const migration=readFileSync("supabase/migrations/202607290001_automatic_finished_goods_linking.sql","utf8");
const ui=readFileSync("src/operational/InventoryCatalogPanel.jsx","utf8");

test("finished goods linking is automatic and idempotent",()=>{
  assert.match(migration,/ensure_finished_goods_inventory_item/);
  assert.match(migration,/where product_id=target_product/);
  assert.match(migration,/after insert or update of name,sku on public\.products/);
  assert.match(migration,/for product_row in select id from public\.products/);
  assert.match(migration,/material_id is null/);
  assert.match(migration,/candidate_count=1/);
  assert.match(migration,/ambiguous_sku/);
  assert.match(migration,/ambiguous_name/);
  assert.match(migration,/FG-/);
});

test("inventory UI distinguishes raw material links from product links",()=>{
  assert.match(ui,/مرتبط تلقائيًا بالمنتج/);
  assert.match(ui,/يحتاج مراجعة الربط/);
  assert.match(ui,/حفظ ربط المادة/);
  assert.match(ui,/item\.product_id/);
  assert.match(ui,/item\.item_type==="raw_material"/);
});