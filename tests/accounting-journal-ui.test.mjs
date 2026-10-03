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

test("journal account selection is search-first by compact code or account name",()=>{
  assert.match(ui,/function JournalAccountPicker/);
  assert.match(ui,/placeholder=\{selected\?"ابحث لتغيير الحساب\.\.\.":"ابحث بالكود أو اسم الحساب\.\.\."\}/);
  assert.match(ui,/accountMatchesLookup\(account,normalized\)/);
  assert.match(ui,/compactAccountCode\(account\.account_code\)/);
  assert.match(ui,/\.slice\(0,8\)/);
  assert.doesNotMatch(
    ui.match(/function JournalEditor[\s\S]*?\n}\n\nexport function JournalWorkspace/)?.[0] || "",
    /<select aria-label=\{"حساب السطر "/,
  );
});

test("journal details display account codes without dots while preserving account ids",()=>{
  assert.match(ui,/compactAccountCode\(accounts\.find\(\(a\)=>a\.id===line\.account_id\)\?\.account_code\)/);
  assert.match(ui,/account_id:line\.account_id/);
});
