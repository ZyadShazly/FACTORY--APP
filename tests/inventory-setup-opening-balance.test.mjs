import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";

const migration=await readFile(new URL("../supabase/migrations/20260726103045_inventory_setup_opening_balance.sql",import.meta.url),"utf8");
const catalog=await readFile(new URL("../src/operational/InventoryCatalogPanel.jsx",import.meta.url),"utf8");
const materials=await readFile(new URL("../src/operational/MaterialsCatalogWorkspace.jsx",import.meta.url),"utf8");
const opening=await readFile(new URL("../src/operational/OpeningInventoryPanel.jsx",import.meta.url),"utf8");
const workspace=await readFile(new URL("../src/operational/InventoryWorkspace.jsx",import.meta.url),"utf8");
const receipt=await readFile(new URL("../supabase/migrations/202607260001_inventory_material_catalog.sql",import.meta.url),"utf8");
const operations=await readFile(new URL("../supabase/migrations/202607210001_inventory_operations.sql",import.meta.url),"utf8");

test("inventory item can be created from an unlinked material with audit",()=>{
  assert.match(migration,/function public\.create_inventory_item/);
  assert.match(migration,/values\(btrim\(item_sku\),btrim\(item_name\),btrim\(item_unit\),target_material/);
  assert.match(migration,/inventory_item_created/);
  assert.match(materials,/إنشاء صنف مخزون من المادة/);
  assert.match(catalog,/item_name:form\.name\.trim\(\).*item_unit:form\.unit\.trim\(\)/s);
});

test("duplicate SKU and duplicate material links are rejected explicitly",()=>{
  assert.match(migration,/pg_catalog\.pg_advisory_xact_lock/);
  assert.match(migration,/lower\(btrim\(i\.sku\)\)=lower\(btrim\(item_sku\)\)/);
  assert.match(migration,/Inventory SKU already exists/);
  assert.match(migration,/Material is already linked to another inventory item/);
});

test("unlinked materials are returned and actionable in setup UI",()=>{
  assert.match(migration,/'unlinked_materials'/);
  assert.match(migration,/left join public\.inventory_items i on i\.material_id=m\.id[\s\S]*m\.active and i\.id is null/);
  assert.match(catalog,/يوجد مواد خام غير مربوطة\. أنشئ صنف مخزون لبدء تسجيل الأرصدة والاستلام\./);
});

test("opening inventory uses draft documents and does not touch balances before posting",()=>{
  const create=migration.match(/create or replace function public\.create_opening_inventory_document[\s\S]*?end \$\$;/)?.[0]||"";
  const save=migration.match(/create or replace function public\.save_opening_inventory_line[\s\S]*?end \$\$;/)?.[0]||"";
  assert.match(migration,/status text not null default 'draft'/);
  assert.doesNotMatch(create,/inventory_balances|inventory_movements/);
  assert.doesNotMatch(save,/inventory_balances|inventory_movements/);
  assert.match(opening,/المسودة لا تؤثر على الرصيد/);
});

test("posting opening inventory updates quantity and value through the ledger",()=>{
  const post=migration.match(/create or replace function public\.post_opening_inventory_document[\s\S]*?end \$\$;/)?.[0]||"";
  assert.match(post,/insert into public\.inventory_movements/);
  assert.match(post,/'opening_balance'/);
  assert.match(post,/line\.quantity,line\.unit_cost/);
  assert.doesNotMatch(post,/update public\.inventory_balances/);
  assert.match(migration,/inventory_movement_balance_after_insert|existing catalog rows/);
});

test("opening inventory cannot post twice and posted data is immutable",()=>{
  assert.match(migration,/if document_row\.status<>'draft' then raise exception 'Opening inventory document is already posted'/);
  assert.match(migration,/inventory_opening_line_once_idx/);
  assert.match(migration,/opening_inventory_document_immutable/);
  assert.match(migration,/opening_inventory_line_immutable/);
  assert.match(migration,/Posted opening inventory is immutable/);
  assert.match(migration,/Posted opening inventory cannot be deleted/);
});

test("unused material deletion is reasoned and stores the complete previous row",()=>{
  const guardedDelete=migration.match(/create or replace function public\.delete_inventory_setup_entity[\s\S]*?end \$\$;/)?.[0]||"";
  assert.match(guardedDelete,/Deletion reason is required/);
  assert.match(guardedDelete,/to_jsonb\(material_row\)/);
  assert.match(guardedDelete,/material_deleted/);
  assert.match(guardedDelete,/delete from public\.materials where id=target_id/);
});

test("referenced material deletion is blocked and archive is offered",()=>{
  for(const reference of [
    "material_purchases","purchase_request_items","supplier_quote_items",
    "purchase_order_items","goods_receipt_items","inventory_items","production_bom"
  ])assert.match(migration,new RegExp(reference));
  assert.match(migration,/Raw material has operational references; archive it instead/);
  assert.match(materials,/أرشفة/);
  assert.match(migration,/function public\.set_material_active/);
});

test("deactivation preserves historical movements",()=>{
  const manage=migration.match(/create or replace function public\.manage_inventory_item_catalog[\s\S]*?end \$\$;/)?.[0]||"";
  assert.match(manage,/set material_id=target_material,active=coalesce\(target_active,active\)/);
  assert.doesNotMatch(manage,/delete from public\.inventory_movements/);
  assert.match(catalog,/تعطيل/);
});

test("goods receipt to inventory remains linked and compatible",()=>{
  assert.match(receipt,/confirm_goods_receipt_to_inventory/);
  assert.match(receipt,/post_goods_receipt_to_inventory/);
  assert.match(receipt,/i\.material_id=line\.material_id and i\.active/);
  assert.match(migration,/'receipt'/);
});

test("existing transfer adjustment count production and receipt movement types remain compatible",()=>{
  for(const movementType of [
    "receipt","project_issue","receipt_reversal","project_issue_reversal",
    "adjustment_in","adjustment_out","transfer_in","transfer_out",
    "production_return","waste_out","damage_out"
  ])assert.match(migration,new RegExp(`'${movementType}'`));
  for(const rpc of ["transfer_inventory","adjust_inventory","create_inventory_count_session","post_inventory_count_session"]){
    assert.match(operations,new RegExp(`function public\\.${rpc}`));
  }
});

test("new tables are RPC-only and privileged functions use a restricted search path",()=>{
  assert.match(migration,/revoke all on public\.opening_inventory_documents,public\.opening_inventory_lines[\s\S]*from public,anon,authenticated/);
  assert.doesNotMatch(migration,/grant (insert|update|delete).*opening_inventory/i);
  for(const name of [
    "create_inventory_item","manage_inventory_item_catalog","set_material_active",
    "delete_inventory_setup_entity","create_opening_inventory_document",
    "save_opening_inventory_line","delete_opening_inventory_line",
    "post_opening_inventory_document","get_inventory_workspace"
  ]){
    assert.match(migration,new RegExp(`function public\\.${name}[\\s\\S]*?security definer set search_path=''`));
  }
});

test("opening inventory is a separate clear section with drafts review and posted history",()=>{
  assert.match(workspace,/OpeningInventoryPanel/);
  for(const label of ["المسودات","إجمالي الكمية","إجمالي القيمة","مراجعة واعتماد / ترحيل","السجل المرحّل"]){
    assert.match(opening,new RegExp(label));
  }
});
