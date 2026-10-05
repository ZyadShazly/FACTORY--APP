import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { parseJournalImportCsv } from "../src/accounting/accountingExports.js";

const migration=fs.readFileSync(
  "supabase/migrations/20261005205500_accounting_journal_import.sql",
  "utf8",
);
const journalUi=fs.readFileSync("src/accounting/JournalWorkspace.jsx","utf8");
const accountUi=fs.readFileSync("src/accounting/AccountingWorkspace.jsx","utf8");
const reportUi=fs.readFileSync("src/accounting/AccountingReportsWorkspace.jsx","utf8");
const exportsModule=fs.readFileSync("src/accounting/accountingExports.js","utf8");

test("journal import is protected atomic draft creation only",()=>{
  assert.match(migration,/create or replace function public\.import_accounting_journal_drafts\(import_entries jsonb\)/);
  assert.match(migration,/accounting_permission_allowed\('accounting_journal_create'\)/);
  assert.match(migration,/origin_value not in \('manual','opening'\)/);
  assert.match(migration,/saved:=public\.create_accounting_journal/);
  assert.match(migration,/abs\(total_debit-total_credit\)>=0\.005/);
  assert.match(migration,/jsonb_array_length\(import_entries\)>500/);
  assert.doesNotMatch(migration,/post_accounting_journal/);
  assert.match(migration,/revoke all on function public\.import_accounting_journal_drafts\(jsonb\)[\s\S]*from public,anon/);
  assert.match(migration,/grant execute on function public\.import_accounting_journal_drafts\(jsonb\)[\s\S]*to authenticated/);
});

test("journal import accepts compact codes but rejects ambiguous compact matches",()=>{
  assert.match(migration,/regexp_replace\(lower\(raw_code\),'\\\.','','g'\)/);
  assert.match(migration,/matched_count>1/);
  assert.match(migration,/use the canonical dotted code/);
});

test("CSV parser groups multiple lines into one journal",()=>{
  const csv=[
    "entry_key,entry_date,reference,description,entry_origin,account_code,debit,credit,line_description",
    "J1,2026-10-05,R1,Imported,manual,1102,100,0,Debit",
    "J1,2026-10-05,R1,Imported,manual,690,0,100,Credit",
  ].join("\n");
  const entries=parseJournalImportCsv(csv);
  assert.equal(entries.length,1);
  assert.equal(entries[0].entry_key,"J1");
  assert.equal(entries[0].lines.length,2);
  assert.equal(entries[0].lines[0].account_code,"1102");
});

test("journal UI exposes print, Excel export, template and import actions",()=>{
  assert.match(journalUi,/طباعة \/ PDF/);
  assert.match(journalUi,/تصدير Excel/);
  assert.match(journalUi,/قالب الاستيراد/);
  assert.match(journalUi,/استيراد قيود/);
  assert.match(journalUi,/import_accounting_journal_drafts/);
  assert.match(journalUi,/ينشئ <b>مسودات فقط<\/b>/);
});

test("chart and accounting reports expose Excel exports",()=>{
  assert.match(accountUi,/exportChartOfAccounts\(accounts\)/);
  assert.match(accountUi,/تصدير Excel/);
  assert.match(reportUi,/exportLedgerReport/);
  assert.match(reportUi,/exportTrialBalanceReport/);
  assert.match(reportUi,/exportBalanceSheetReport/);
  assert.match(reportUi,/exportProfitLossReport/);
});

test("accounting export module covers chart journals reports and print",()=>{
  for(const name of [
    "exportChartOfAccounts",
    "exportJournalRegister",
    "printJournal",
    "downloadJournalImportTemplate",
    "exportLedgerReport",
    "exportTrialBalanceReport",
    "exportBalanceSheetReport",
    "exportProfitLossReport",
  ]) assert.match(exportsModule,new RegExp(`export function ${name}`));
});
