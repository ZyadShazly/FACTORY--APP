import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929064016_accounting_reports_core.sql",
  "utf8",
);

test("reports core exposes ledger, trial balance and balance sheet RPCs",()=>{
  assert.match(sql,/create or replace function public\.get_accounting_account_ledger\(/);
  assert.match(sql,/create or replace function public\.get_accounting_trial_balance\(/);
  assert.match(sql,/create or replace function public\.get_accounting_balance_sheet\(/);
});

test("all accounting reports read current posted GL lines including reversed originals",()=>{
  const statusMatches=sql.match(/j\.status in \('posted','reversed'\)/g)||[];
  assert.ok(statusMatches.length>=6);
  assert.doesNotMatch(sql,/j\.status='posted'/);
  assert.doesNotMatch(sql,/accounting_journal_revisions[\s\S]*sum\(/i);
});

test("account ledger derives opening and running balances from current journal lines",()=>{
  assert.match(sql,/opening_raw[\s\S]*sum\(l\.debit-l\.credit\)/);
  assert.match(sql,/sum\(l\.debit-l\.credit\) over\(/);
  assert.match(sql,/source_module/);
  assert.match(sql,/source_record_id/);
  assert.match(sql,/revision_number/);
  assert.match(sql,/master_overridden/);
});

test("trial balance aggregates descendants but computes scope totals from direct lines once",()=>{
  assert.match(sql,/descendants as \(/);
  assert.match(sql,/d\.ancestor_id=a\.id/);
  assert.match(sql,/scope_totals as \([\s\S]*from direct d/);
  assert.match(sql,/opening_debit/);
  assert.match(sql,/opening_credit/);
  assert.match(sql,/period_debit/);
  assert.match(sql,/period_credit/);
  assert.match(sql,/closing_debit/);
  assert.match(sql,/closing_credit/);
  assert.match(sql,/full_gl_balanced/);
});

test("balance sheet is derived and current P&L flows into equity exactly once",()=>{
  assert.match(sql,/current_profit:=revenue_total-cost_total-expense_total/);
  assert.match(sql,/ledger_equity_excluding_cypl\+current_profit/);
  assert.match(sql,/current_year_profit_loss_mapping/);
  assert.match(sql,/presentation_is_derived',true/);
  assert.match(sql,/total_assets-\(total_liabilities\+total_equity\)/);
  assert.doesNotMatch(sql,/create table public\.accounting_balance_sheet/i);
});

test("current-year P&L uses configurable account mapping rather than a hard-coded account id",()=>{
  assert.match(sql,/mapping_key[\s\S]*'current_year_profit_loss'/);
  assert.match(sql,/m\.account_id/);
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("report RPCs are permission checked and not callable by anon or PUBLIC",()=>{
  assert.match(sql,/private\.accounting_permission_allowed\('accounting_reports_view'\)/);
  for(const fn of [
    "get_accounting_account_ledger\\(uuid,date,date,uuid\\)",
    "get_accounting_trial_balance\\(date,date,uuid,text,uuid\\)",
    "get_accounting_balance_sheet\\(date\\)",
  ]){
    assert.match(sql,new RegExp(`revoke all on function public\\.${fn} from public,anon`));
    assert.match(sql,new RegExp(`grant execute on function public\\.${fn} to authenticated`));
  }
});

test("reports migration remains additive to operational modules",()=>{
  assert.doesNotMatch(sql,/drop\s+table/i);
  assert.doesNotMatch(sql,/truncate\s+/i);
  assert.doesNotMatch(sql,/alter\s+table\s+public\.(sales|expenses|supplier_invoices|supplier_payments|customer_receipts|inventory_movements|projects|payroll|daily_labor)/i);
  assert.doesNotMatch(sql,/(insert|update|delete)\s+(into\s+|from\s+)?public\.(sales|expenses|supplier_invoices|supplier_payments|customer_receipts|inventory_movements|projects|payroll|daily_labor)/i);
});
