import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260930082013_accounting_balance_sheet_rollforward.sql",
  "utf8",
);

test("balance sheet roll-forward maps retained earnings without hard-coded account ids",()=>{
  assert.match(sql,/mapping_key[\s\S]*retained_earnings/);
  assert.match(sql,/suggested_account_code[\s\S]*3\.2/);
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("current and cumulative P&L are computed separately",()=>{
  assert.match(sql,/current_profit:=revenue_total-cost_total-expense_total/);
  assert.match(sql,/cumulative_profit:=[\s\S]*cumulative_revenue-cumulative_cost-cumulative_expense/);
  assert.match(sql,/prior_unclosed_profit:=cumulative_profit-current_profit/);
});

test("total equity uses cumulative unclosed P&L",()=>{
  assert.match(sql,/total_equity:=[\s\S]*ledger_equity_excluding_cypl\+cumulative_profit/);
});

test("equity presentation injects current P&L and prior unclosed P&L into separate mapped accounts",()=>{
  assert.match(sql,/x\.descendant_id=cypl_account[\s\S]*then current_profit/);
  assert.match(sql,/x\.descendant_id=retained_account[\s\S]*then prior_unclosed_profit/);
  assert.match(sql,/retained_earnings_mapping/);
  assert.match(sql,/presentation_adjustment',prior_unclosed_profit/);
});

test("migration is reporting-only and non-destructive",()=>{
  assert.doesNotMatch(sql,/drop\s+table/i);
  assert.doesNotMatch(sql,/truncate\s+/i);
  assert.doesNotMatch(sql,/delete\s+from\s+public\./i);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries/i);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_lines/i);
});
