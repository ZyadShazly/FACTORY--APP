import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const ui=fs.readFileSync("src/accounting/AccountingMappingsWorkspace.jsx","utf8");
const shell=fs.readFileSync("src/accounting/AccountingWorkspace.jsx","utf8");

test("accounting shell exposes account mapping workspace",()=>{
  assert.match(shell,/ربط الحسابات/);
  assert.match(shell,/AccountingMappingsWorkspace/);
});

test("mapping UI uses protected RPCs only",()=>{
  for(const rpc of[
    "get_accounting_mapping_workspace",
    "owner_set_accounting_mapping",
    "owner_clear_accounting_mapping",
  ]) assert.match(ui,new RegExp(`supabase\\.rpc\\("${rpc}"`));
  assert.doesNotMatch(ui,/supabase\.from\("accounting_/);
});

test("owner can select eligible posting accounts and accept suggestions without forced mapping",()=>{
  assert.match(ui,/a\.is_active&&a\.is_posting/);
  assert.match(ui,/expected_account_types/);
  assert.match(ui,/المقترح:/);
  assert.match(ui,/الحسابات المقترحة ليست إجبارية/);
  assert.match(ui,/profile\?\.role==="owner"/);
});

test("mapping clear requires a reason and preserves prior journal history",()=>{
  assert.match(ui,/سبب إلغاء الربط مطلوب/);
  assert.match(ui,/إلغاء الربط لا يغير أي قيد سابق/);
  assert.match(ui,/Auto-posting المستقبلية/);
});

test("workspace shows module readiness without claiming auto-posting is live",()=>{
  assert.match(ui,/auto_posting_readiness/);
  assert.match(ui,/جاهز للربط لاحقًا/);
  assert.match(ui,/لا توجد عملية تشغيلية تولّد قيودًا تلقائية حتى الآن/);
});
