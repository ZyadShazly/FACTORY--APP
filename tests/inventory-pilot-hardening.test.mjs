import assert from"node:assert/strict";
import{readFile}from"node:fs/promises";
import test from"node:test";

const workspace=await readFile(new URL("../src/operational/InventoryWorkspace.jsx",import.meta.url),"utf8");
const catalog=await readFile(new URL("../src/operational/InventoryCatalogPanel.jsx",import.meta.url),"utf8");
const materials=await readFile(new URL("../src/operational/MaterialsCatalogWorkspace.jsx",import.meta.url),"utf8");
const procurement=await readFile(new URL("../src/operational/ProcurementWorkspace.jsx",import.meta.url),"utf8");
const ui=await readFile(new URL("../src/operational/ui.jsx",import.meta.url),"utf8");
const shell=await readFile(new URL("../src/AppMonolith.jsx",import.meta.url),"utf8");
const css=await readFile(new URL("../src/operational/inventoryWorkspace.css",import.meta.url),"utf8");

test("inventory explains the five distinct inventory concepts on demand",()=>{
  for(const concept of["المادة الخام","صنف المخزون","رصيد المخزن","الرصيد الافتتاحي","حركة المخزون"]){
    assert.match(catalog,new RegExp(concept));
  }
  assert.match(catalog,/<details className="inventory-concepts">/);
});

test("raw materials expose their current linked inventory item name and code",()=>{
  assert.match(materials,/linkedByMaterial/);
  assert.match(materials,/linkedItem\.name/);
  assert.match(materials,/linkedItem\.sku/);
  assert.match(materials,/فتح صنف المخزون/);
});

test("new materials refresh and provide direct create or link actions",()=>{
  const add=materials.match(/async function add\(\)[\s\S]*?\n  \}/)?.[0]||"";
  assert.match(add,/await refreshSetup\(\)/);
  assert.match(materials,/إنشاء صنف مخزون من المادة/);
  assert.match(materials,/ربط بصنف موجود/);
  assert.match(shell,/MaterialsTab[\s\S]*onNavigate=\{setTab\}/);
});

test("link selector excludes materials already owned by another inventory item",()=>{
  assert.match(catalog,/linkedMaterialIds/);
  assert.match(catalog,/material\.id===item\.material_id\|\|!linkedMaterialIds\.has\(material\.id\)/);
});

test("receipt link failures are friendly and route directly to inventory linking",()=>{
  assert.match(ui,/Receipt material is not linked to an active inventory item/);
  assert.match(ui,/افتح أصناف المخزون واربط المادة ثم أعد الاستلام/);
  assert.match(procurement,/setLinkingRequired/);
  assert.match(procurement,/فتح ربط المواد في المخزون/);
  assert.match(procurement,/onNavigate\("inventory"\)/);
  assert.match(shell,/ProcurementWorkspace data=\{data\} onNavigate=\{setTab\}/);
});

test("pilot hardening preserves protected RPC boundaries and adds no direct writes",()=>{
  for(const source of[workspace,catalog,procurement])assert.doesNotMatch(source,/supabase\.from\(/);
  assert.match(catalog,/"manage_inventory_item_catalog"/);
  assert.match(procurement,/"confirm_goods_receipt_to_inventory"/);
});

test("inventory grid contains wide children without global mobile overflow",()=>{
  assert.match(css,/\.inventory-workspace\{[^}]*grid-template-columns:minmax\(0,1fr\)/);
  assert.match(css,/\.inventory-workspace>\*\{min-width:0;max-width:100%\}/);
  assert.match(css,/\.inventory-table-wrap\{overflow-x:auto/);
});
