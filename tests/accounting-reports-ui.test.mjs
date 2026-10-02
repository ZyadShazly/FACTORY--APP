import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const ui=fs.readFileSync("src/accounting/AccountingReportsWorkspace.jsx","utf8");
const shell=fs.readFileSync("src/accounting/AccountingWorkspace.jsx","utf8");
const app=fs.readFileSync("src/AppMonolith.jsx","utf8");

test("accounting workspace exposes protected reports tab",()=>{
  assert.match(shell,/التقارير المحاسبية/);
  assert.match(shell,/permissions\?\.accounting_reports_view/);
  assert.match(shell,/AccountingReportsWorkspace/);
});

test("reports UI uses protected report RPCs and no direct accounting table reads",()=>{
  for(const rpc of [
    "get_accounting_account_ledger",
    "get_accounting_trial_balance",
    "get_accounting_balance_sheet",
    "get_accounting_profit_loss",
  ]) assert.match(ui,new RegExp(`supabase\\.rpc\\("${rpc}"`));
  assert.doesNotMatch(ui,/supabase\.from\("accounting_/);
});

test("ledger exposes traceability fields and running balance",()=>{
  assert.match(ui,/الرصيد الافتتاحي/);
  assert.match(ui,/الرصيد الجاري/);
  assert.match(ui,/source_module/);
  assert.match(ui,/source_record_id/);
  assert.match(ui,/Master Rev/);
});

test("trial balance exposes opening period and closing debit-credit columns",()=>{
  for(const label of ["افتتاحي مدين","افتتاحي دائن","حركة مدين","حركة دائن","ختامي مدين","ختامي دائن"]){
    assert.match(ui,new RegExp(label));
  }
  assert.match(ui,/دفتر الأستاذ متزن/);
  assert.match(ui,/صفوف الحسابات التجميعية/);
});

test("trial balance and balance sheet drill down into account ledger",()=>{
  assert.match(ui,/const openLedger=\(accountId\)=>\{setLedgerAccount\(accountId\);setReportTab\("ledger"\)\}/);
  assert.match(ui,/onOpenLedger\(row\.id\)/);
});

test("balance sheet displays accounting equation and derived current period profit once",()=>{
  assert.match(ui,/إجمالي الأصول/);
  assert.match(ui,/إجمالي الالتزامات/);
  assert.match(ui,/إجمالي حقوق الملكية/);
  assert.match(ui,/الالتزامات \+ حقوق الملكية/);
  assert.match(ui,/r\.id!==cyplId/);
  assert.match(ui,/ربح \/ خسارة الفترة الحالية/);
});

test("accounting shell supplies project filters from existing project data",()=>{
  assert.match(app,/<AccountingWorkspace profile=\{profile\} permissions=\{permissions\} projects=\{data\.projects\}/);
  assert.match(ui,/كل المشاريع/);
});

test("profit and loss report exposes period project filters and GL-derived totals",()=>{
  assert.match(ui,/قائمة الأرباح والخسائر/);
  assert.match(ui,/الأرباح والخسائر/);
  assert.match(ui,/مجمل الربح/);
  assert.match(ui,/صافي الربح \/ الخسارة/);
  assert.match(ui,/target_project:filters\.project_id\|\|null/);
  assert.match(ui,/summary\.revenue/);
  assert.match(ui,/summary\.cost_of_sales/);
  assert.match(ui,/summary\.expenses/);
  assert.match(ui,/summary\.profit_loss/);
});
