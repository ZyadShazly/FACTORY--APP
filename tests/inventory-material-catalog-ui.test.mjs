import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const panel=await readFile(new URL('../src/operational/InventoryCatalogPanel.jsx',import.meta.url),'utf8');
const workspace=await readFile(new URL('../src/operational/InventoryWorkspace.jsx',import.meta.url),'utf8');

test('inventory workspace exposes catalog management to managers',()=>{
  assert.match(workspace,/InventoryCatalogPanel/);
  assert.match(workspace,/catalog:\[\],materials:\[\]/);
});

test('catalog keeps raw material management and automatic finished goods links separate',()=>{
  for(const label of ['حفظ ربط المادة','فك ربط المادة','تعطيل','تنشيط'])assert.match(panel,new RegExp(label));
  assert.match(panel,/manage_inventory_item_catalog/);
  assert.match(panel,/مرتبط تلقائيًا بالمنتج/);
  assert.match(panel,/يحتاج مراجعة الربط/);
  assert.match(panel,/item\.product_id/);
});

test('catalog explains receipt prerequisite and automatic product reconciliation',()=>{
  assert.match(panel,/قبل الاستلام/);
  assert.match(panel,/يربطها النظام تلقائيًا/);
  assert.match(panel,/عند الحاجة للمراجعة/);
});