import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration=await readFile(new URL('../supabase/migrations/202607260001_inventory_material_catalog.sql',import.meta.url),'utf8');

test('inventory workspace exposes full catalog and materials',()=>{
  assert.match(migration,/'catalog'/);
  assert.match(migration,/'materials'/);
  assert.match(migration,/left join public\.materials m on m\.id=i\.material_id/);
});

test('catalog management is protected and audited',()=>{
  assert.match(migration,/function public\.manage_inventory_item_catalog/);
  assert.match(migration,/private\.inventory_manage_allowed\(\)/);
  assert.match(migration,/inventory_catalog_updated/);
  assert.match(migration,/material_link_changed/);
  assert.match(migration,/active_changed/);
});

test('deactivation cannot hide stock and duplicate links are rejected',()=>{
  assert.match(migration,/Cannot deactivate an inventory item with stock/);
  assert.match(migration,/This material is already linked to another inventory item/);
});

test('receipt validates active material linkage before confirming receipt',()=>{
  const preflight=migration.indexOf('يجب ربط المادة');
  const confirmation=migration.indexOf('receipt:=public.confirm_goods_receipt(payload)');
  assert.ok(preflight>0);
  assert.ok(confirmation>preflight);
  assert.match(migration,/i\.material_id=poi\.material_id and i\.active/);
});
