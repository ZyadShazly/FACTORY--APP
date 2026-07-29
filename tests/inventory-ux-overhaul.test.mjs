import assert from"node:assert/strict";
import{readFile}from"node:fs/promises";
import test from"node:test";

const workspace=await readFile(new URL("../src/operational/InventoryWorkspace.jsx",import.meta.url),"utf8");
const catalog=await readFile(new URL("../src/operational/InventoryCatalogPanel.jsx",import.meta.url),"utf8");
const opening=await readFile(new URL("../src/operational/OpeningInventoryPanel.jsx",import.meta.url),"utf8");
const warehouses=await readFile(new URL("../src/operational/WarehouseManagementPanel.jsx",import.meta.url),"utf8");
const shell=await readFile(new URL("../src/AppMonolith.jsx",import.meta.url),"utf8");
const css=await readFile(new URL("../src/operational/inventoryWorkspace.css",import.meta.url),"utf8");

test("inventory dashboard has exactly the four requested KPIs",()=>{
  const kpis=[...workspace.matchAll(/<Kpi label="([^"]+)"/g)].map(match=>match[1]);
  assert.deepEqual(kpis,["أصناف المخزون","قيمة المخزون","إجمالي الكمية","مواد خام غير مربوطة"]);
  assert.equal(kpis.length,4);
});

test("primary inventory actions stay visible and route to existing workflows",()=>{
  for(const label of["+ صنف مخزون جديد","+ رصيد افتتاحي","+ استلام","+ صرف"])assert.match(workspace,new RegExp(label.replace("+","\\+")));
  assert.match(css,/inventory-primary-actions\{position:sticky/);
  assert.match(workspace,/onNavigate\?\.\("purchases"\)/);
  assert.match(workspace,/onNavigate\?\.\("production"\)/);
  assert.match(shell,/InventoryTab canViewFinancials=\{permissions\.view_financials\} onNavigate=\{setTab\} allowedPages=\{permissions\.pages \|\| \[\]\}/);
});

test("workspace separates items opening operations history and settings",()=>{
  for(const id of["items","opening","operations","history","settings"])assert.match(workspace,new RegExp(`id:"${id}"`));
  for(const label of["أصناف المخزون","الرصيد الافتتاحي","العمليات","السجل","الإعدادات"])assert.match(workspace,new RegExp(label));
  assert.match(workspace,/aria-label="أقسام مساحة المخزون"/);
});

test("operations expose receive issue transfer adjustment and count one at a time",()=>{
  for(const id of["receive","issue","transfer","adjustment","count"])assert.match(workspace,new RegExp(`id:"${id}"`));
  for(const branch of['operation==="receive"','operation==="issue"','operation==="transfer"','operation==="adjustment"','operation==="count"'])assert.ok(workspace.includes(branch),branch);
  assert.match(workspace,/اختر العملية المطلوبة فقط؛ لن تظهر النماذج الأخرى في نفس الوقت/);
});

test("inventory item table shows required fields and separates raw from finished links",()=>{
  for(const heading of["الاسم","الكود","الكمية","المخزن","الحالة","الارتباط","الإجراءات"])assert.match(catalog,new RegExp(heading));
  for(const action of["إنشاء من المادة","حفظ ربط المادة","فك ربط المادة","تنشيط","تعطيل"])assert.match(catalog,new RegExp(action));
  assert.match(catalog,/مرتبط تلقائيًا بالمنتج/);
  assert.match(catalog,/يحتاج مراجعة الربط/);
  assert.match(catalog,/balanceSummary/);
  assert.match(catalog,/inventory-table/);
});

test("history is movement-only and archive\/history surfaces are collapsed",()=>{
  const historyBranch=workspace.slice(workspace.indexOf('tab==="history"'),workspace.indexOf('tab==="settings"'));
  assert.match(historyBranch,/workspace\.movements/);
  assert.doesNotMatch(historyBranch,/opening_documents|count_sessions|warehouse_admin/);
  assert.match(opening,/<details className="inventory-collapsible">/);
  assert.match(warehouses,/المخازن المؤرشفة/);
  assert.match(warehouses,/<details className="inventory-collapsible">/);
});

test("UX overhaul preserves protected RPC contracts and avoids direct writes",()=>{
  for(const rpc of[
    "get_inventory_workspace","transfer_inventory","adjust_inventory",
    "create_inventory_count_session","save_inventory_count_line","post_inventory_count_session"
  ])assert.match(workspace,new RegExp(`"${rpc}"`));
  for(const rpc of["create_inventory_item","manage_inventory_item_catalog","delete_inventory_setup_entity"])assert.match(catalog,new RegExp(`"${rpc}"`));
  for(const rpc of["create_opening_inventory_document","save_opening_inventory_line","delete_opening_inventory_line","post_opening_inventory_document"])assert.match(opening,new RegExp(`"${rpc}"`));
  for(const rpc of["save_inventory_warehouse","save_inventory_location","get_inventory_warehouse_detail","archive_inventory_warehouse"])assert.match(warehouses,new RegExp(`"${rpc}"`));
  for(const source of[workspace,catalog,opening,warehouses])assert.doesNotMatch(source,/supabase\.from\(/);
});

test("inventory workspace remains responsive without hiding required actions",()=>{
  assert.match(css,/@media\(max-width:1000px\)/);
  assert.match(css,/@media\(max-width:700px\)/);
  assert.match(css,/inventory-primary-actions[\s\S]*grid-template-columns:repeat\(2/);
  assert.match(css,/inventory-tabs[\s\S]*overflow-x:auto/);
  assert.match(css,/inventory-table-wrap\{overflow-x:auto/);
});