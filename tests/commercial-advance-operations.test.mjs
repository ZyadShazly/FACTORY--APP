import test from"node:test";
import assert from"node:assert/strict";
import{readFile}from"node:fs/promises";

const migration=await readFile(new URL("../supabase/migrations/20260810160000_commercial_advance_operations.sql",import.meta.url),"utf8");
const panel=await readFile(new URL("../src/operational/CommercialAdvancesPanel.jsx",import.meta.url),"utf8");
const app=await readFile(new URL("../src/AppMonolith.jsx",import.meta.url),"utf8");
const ui=await readFile(new URL("../src/operational/ui.jsx",import.meta.url),"utf8");

test("commercial advance workspace is protected and returns the complete operational cycle",()=>{
  assert.match(migration,/get_commercial_advance_workspace\(party_type text,target_party uuid\)/);
  for(const key of["sources","targets","allocations","transactions","due"])assert.match(migration,new RegExp(`'${key}'`));
  assert.match(migration,/security definer\s+set search_path=''/);
  assert.match(migration,/revoke all on function public\.get_commercial_advance_workspace\(text,uuid\)[\s\S]*from public,anon/);
  assert.match(migration,/grant execute on function public\.get_commercial_advance_workspace\(text,uuid\)[\s\S]*to authenticated/);
});

test("allocations are idempotent, document-capped, serialized and cancellation-safe",()=>{
  assert.match(migration,/command_id=allocate_customer_advance\.command_id/);
  assert.match(migration,/command_id=allocate_supplier_advance\.command_id/);
  assert.match(migration,/for update/);
  assert.match(migration,/Allocation exceeds customer document balance/);
  assert.match(migration,/Allocation exceeds supplier document balance/);
  assert.match(migration,/guard_active_advance_target/);
  assert.match(migration,/Reverse active advance allocations before cancelling or deleting this document/);
});

test("customer and supplier screens can allocate and reverse without direct table access",()=>{
  assert.match(panel,/"allocate_customer_advance"/);
  assert.match(panel,/"allocate_supplier_advance"/);
  assert.match(panel,/"reverse_advance_allocation"/);
  assert.match(panel,/"reverse_classified_cash_transaction"/);
  assert.match(panel,/command_id:commandId/);
  assert.doesNotMatch(panel,/supabase\.from\(/);
  assert.match(app,/CommercialAdvancesPanel partyType="customer"/);
  assert.match(app,/CommercialAdvancesPanel partyType="supplier"/);
  assert.match(app,/record_customer_receipt[\s\S]*command_id: commandId/);
  assert.match(app,/record_supplier_payment[\s\S]*command_id: commandId/);
});

test("advance workflow server failures have actionable Arabic messages",()=>{
  assert.match(ui,/مبلغ التخصيص أكبر من الرصيد المتبقي على مستند العميل/);
  assert.match(ui,/اعكس تخصيصات السلفة النشطة/);
});
