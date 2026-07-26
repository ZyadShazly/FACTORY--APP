import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const panel=await readFile(new URL('../src/operational/InventoryCatalogPanel.jsx',import.meta.url),'utf8');
const workspace=await readFile(new URL('../src/operational/InventoryWorkspace.jsx',import.meta.url),'utf8');

test('inventory workspace exposes catalog management to managers',()=>{
  assert.match(workspace,/InventoryCatalogPanel/);
  assert.match(workspace,/catalog:\[\],materials:\[\]/);
});

test('catalog supports link unlink activate and deactivate actions',()=>{
  for(const label of ['حفظ الربط','فك الربط','تعطيل','تنشيط'])assert.match(panel,new RegExp(label));
  assert.match(panel,/manage_inventory_item_catalog/);
});

test('catalog explains history safety and receipt prerequisite',()=>{
  assert.match(panel,/قبل الاستلام/);
  assert.match(panel,/لا يحذف أي حركة تاريخية/);
});
