import test from"node:test";
import assert from"node:assert/strict";
import fs from"node:fs";

const migration=fs.readFileSync("supabase/migrations/202607220001_warehouse_management_workflow.sql","utf8");
const inventory=fs.readFileSync("src/operational/InventoryWorkspace.jsx","utf8");
const panel=fs.readFileSync("src/operational/WarehouseManagementPanel.jsx","utf8");

test("warehouse migration preserves history and blocks unsafe archive",()=>{
  assert.match(migration,/archive_inventory_warehouse/);
  assert.match(migration,/quantity_on_hand<>0/);
  assert.match(migration,/status in \('draft','submitted'\)/);
  assert.match(migration,/update public\.inventory_locations set active=false/);
  assert.doesNotMatch(migration,/drop table/i);
  assert.doesNotMatch(migration,/delete from public\.inventory_(warehouses|movements|balances)/i);
});

test("warehouse functions are not available to anon",()=>{
  for(const fn of["save_inventory_warehouse","save_inventory_location","get_inventory_warehouse_detail","archive_inventory_warehouse"]){
    assert.match(migration,new RegExp(`revoke all on function public\\.${fn}\\(`));
    assert.match(migration,new RegExp(`grant execute on function public\\.${fn}\\([^;]+\\) to authenticated`));
  }
});

test("inventory UI exposes review before archive",()=>{
  assert.match(inventory,/WarehouseManagementPanel/);
  assert.match(panel,/فتح التفاصيل/);
  assert.match(panel,/إجمالي الكمية/);
  assert.match(panel,/استلامات مرتبطة/);
  assert.match(panel,/روابط إنتاج/);
  assert.match(panel,/جلسات جرد مفتوحة/);
  assert.match(panel,/سبب الأرشفة/);
  assert.match(panel,/لا يمكن الأرشفة قبل تحويل أو تسوية كل الأرصدة إلى صفر/);
});
