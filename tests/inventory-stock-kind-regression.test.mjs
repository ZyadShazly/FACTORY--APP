import test from"node:test";
import assert from"node:assert/strict";
import{readFileSync}from"node:fs";

const migration=readFileSync("supabase/migrations/202607290003_persist_inventory_stock_kind.sql","utf8");
const panel=readFileSync("src/operational/InventoryCatalogPanel.jsx","utf8");

test("inventory kind is persisted independently from links",()=>{
  assert.match(migration,/add column if not exists stock_kind text/);
  assert.match(migration,/check \(stock_kind in \('raw','finished'\)\)/);
  assert.match(migration,/old\.stock_kind/);
  assert.match(migration,/before insert or update of material_id,product_id,stock_kind/);
});

test("catalog uses explicit stock kind",()=>{
  assert.match(panel,/item\.stock_kind==="raw"/);
  assert.match(panel,/item\.stock_kind==="finished"/);
  assert.match(panel,/نوع الصنف/);
  assert.match(panel,/فك ارتباط المادة لا يحول الصنف إلى منتج تام/);
  assert.doesNotMatch(panel,/Boolean\(item\.material_id\|\|item\.material_name\)/);
});