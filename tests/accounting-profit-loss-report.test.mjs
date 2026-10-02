import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20261002233413_accounting_profit_loss_report.sql",
  "utf8",
);

test("dedicated P&L report is derived from the posted/reversed GL only",()=>{
  assert.match(sql,/create or replace function public\.get_accounting_profit_loss\(/);
  assert.match(sql,/j\.status in \('posted','reversed'\)/);
  assert.match(sql,/a\.account_type in \('revenue','cost_of_sales','expense'\)/);
  assert.match(sql,/target_project is null or coalesce\(l\.project_id,j\.project_id\)=target_project/);
  assert.doesNotMatch(sql,/create table/i);
  assert.doesNotMatch(sql,/(insert|update|delete)\s+(into\s+|from\s+)?public\./i);
});

test("P&L totals use direct lines once and expose the expected accounting formula",()=>{
  assert.match(sql,/'revenue',t\.revenue/);
  assert.match(sql,/'cost_of_sales',t\.cost_of_sales/);
  assert.match(sql,/'gross_profit',t\.revenue-t\.cost_of_sales/);
  assert.match(sql,/'expenses',t\.expenses/);
  assert.match(sql,/'profit_loss',t\.revenue-t\.cost_of_sales-t\.expenses/);
  assert.match(sql,/from totals t/);
});

test("P&L rows aggregate descendants for presentation without reusing parent rows in totals",()=>{
  assert.match(sql,/descendants as \(/);
  assert.match(sql,/x\.ancestor_id=a\.id/);
  assert.match(sql,/coalesce\(sum\(d\.amount\),0\)/);
  assert.match(sql,/from public\.accounting_journal_lines l[\s\S]*join public\.accounting_accounts a[\s\S]*totals as \(/);
});

test("P&L RPC enforces report permission boundary",()=>{
  assert.match(sql,/private\.accounting_report_assert_access\(\)/);
  assert.match(sql,/revoke all on function public\.get_accounting_profit_loss\(date,date,uuid\)[\s\S]*from public,anon/);
  assert.match(sql,/grant execute on function public\.get_accounting_profit_loss\(date,date,uuid\)[\s\S]*to authenticated/);
});
