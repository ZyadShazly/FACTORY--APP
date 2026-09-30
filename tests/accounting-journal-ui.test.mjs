import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const ui=fs.readFileSync("src/accounting/JournalWorkspace.jsx","utf8");
const shell=fs.readFileSync("src/accounting/AccountingWorkspace.jsx","utf8");

test("accounting page exposes journal workspace beside chart of accounts",()=>{
  assert.match(shell,/شجرة الحسابات/);
  assert.match(shell,/القيود اليومية/);
  assert.match(shell,/JournalWorkspace/);
});

test("journal UI uses protected RPCs and never direct accounting table writes",()=>{
  for(const rpc of [
    "get_accounting_journal_workspace",
    "create_accounting_journal",
    "update_accounting_journal_draft",
    "post_accounting_journal",
    "owner_edit_posted_accounting_journal",
    "reverse_accounting_journal",
  ]) assert.match(ui,new RegExp(`supabase\\.rpc\\("${rpc}"`));
  assert.doesNotMatch(ui,/supabase\.from\("accounting_/);
});

test("owner controls accounting activation and periods through protected RPCs",()=>{
  for(const rpc of [
    "owner_configure_accounting",
    "owner_create_accounting_period",
    "owner_lock_accounting_period",
    "owner_reopen_accounting_period",
  ]) assert.match(ui,new RegExp(`supabase\\.rpc\\("${rpc}"|const rpc=.*"${rpc}"`));
  assert.match(ui,/profile\?\.role==="owner"/);
});

test("posted master edit is explicit and tells user balances are updated",()=>{
  assert.match(ui,/posted-edit/);
  assert.match(ui,/سبب تعديل القيد المرحّل/);
  assert.match(ui,/تم تعديل القيد المرحّل وتحديث أرصدة دفتر الأستاذ/);
});

test("journal editor keeps debit and credit mutually exclusive per line",()=>{
  assert.match(ui,/debit:e\.target\.value,credit:e\.target\.value\?"":line\.credit/);
  assert.match(ui,/credit:e\.target\.value,debit:e\.target\.value\?"":line\.debit/);
  assert.match(ui,/إجمالي المدين/);
  assert.match(ui,/إجمالي الدائن/);
});


test("focused journal opens its details and source trace uses protected RPC",()=>{
  assert.match(ui,/focusJournalId/);
  assert.match(ui,/journal-details-/);
  assert.match(ui,/get_accounting_source_trace/);
  assert.match(ui,/عرض العملية الأصلية/);
  assert.match(ui,/source_record_id/);
  assert.match(ui,/source_table/);
  assert.doesNotMatch(ui,/supabase\.from\("(sales|expenses|payroll|inventory_movements|supplier_invoices)"/);
});

test("journal copy reflects that operational auto-posting is live",()=>{
  assert.match(ui,/مرتبط بالعمليات التشغيلية المفعّلة محاسبيًا/);
  assert.doesNotMatch(ui,/لا توجد قيود تلقائية/);
  assert.doesNotMatch(ui,/القيود اليدوية فقط/);
});
