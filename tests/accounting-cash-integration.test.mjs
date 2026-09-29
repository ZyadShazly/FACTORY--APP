import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929073100_accounting_cash_integration.sql",
  "utf8",
);
const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("cash integration is activation-gated and does not backfill history",()=>{
  assert.match(sql,/accounting_source_event_in_scope/);
  assert.match(sql,/s\.enabled/);
  assert.match(sql,/activation_date/);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\.(customer_receipts|supplier_payments|customer_advance_allocations|supplier_advance_allocations)/i);
  assert.match(matrix,/No historical operational row is auto-posted/);
});

test("customer receipts post settlement and advance with configurable mappings",()=>{
  assert.match(sql,/default_cash_bank/);
  assert.match(sql,/accounts_receivable/);
  assert.match(sql,/customer_advances/);
  assert.match(sql,/'account_id',bank_account,'debit',new\.amount,'credit',0/);
  assert.match(sql,/'account_id',ar_account,'debit',0,'credit',new\.settlement_amount/);
  assert.match(sql,/'account_id',customer_advance_account,'debit',0,'credit',new\.advance_amount/);
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("supplier payments post settlement and advance with configurable mappings",()=>{
  assert.match(sql,/accounts_payable/);
  assert.match(sql,/supplier_advances/);
  assert.match(sql,/'account_id',ap_account,'debit',new\.settlement_amount,'credit',0/);
  assert.match(sql,/'account_id',supplier_advance_account,'debit',new\.advance_amount,'credit',0/);
  assert.match(sql,/'account_id',bank_account,'debit',0,'credit',new\.amount/);
});

test("advance allocations move between advance and receivable or payable accounts",()=>{
  assert.match(sql,/customer_advance_allocated/);
  assert.match(sql,/supplier_advance_allocated/);
  assert.match(sql,/'account_id',customer_advance_account,'debit',new\.amount,'credit',0/);
  assert.match(sql,/'account_id',ar_account,'debit',0,'credit',new\.amount/);
  assert.match(sql,/'account_id',ap_account,'debit',new\.amount,'credit',0/);
  assert.match(sql,/'account_id',supplier_advance_account,'debit',0,'credit',new\.amount/);
});

test("system journals are idempotently linked to one canonical source",()=>{
  assert.match(sql,/pg_advisory_xact_lock/);
  assert.match(sql,/accounting_source_links/);
  assert.match(sql,/source_revision=1/);
  assert.match(sql,/if existing_entry is not null then[\s\S]*return existing_entry/);
  assert.match(sql,/entry_origin[\s\S]*'system'/);
  assert.match(sql,/accounting_system_journal_posted/);
});

test("source reversal reverses current journal lines including owner master edits",()=>{
  assert.match(sql,/accounting_reverse_source_journal/);
  assert.match(sql,/private\.reverse_accounting_journal_current_lines/);
  assert.match(sql,/link_status='active'/);
  assert.match(matrix,/current posted lines, including any audited Owner\/Master edit/);
});

test("cash integration hooks current operational tables without replacing their RPC contracts",()=>{
  for(const trigger of[
    "accounting_customer_receipts_post_gl",
    "accounting_supplier_payments_post_gl",
    "accounting_customer_advance_allocations_post_gl",
    "accounting_supplier_advance_allocations_post_gl",
    "accounting_customer_receipts_reverse_gl",
    "accounting_supplier_payments_reverse_gl",
    "accounting_customer_advance_allocations_reverse_gl",
    "accounting_supplier_advance_allocations_reverse_gl",
  ]) assert.match(sql,new RegExp("create trigger "+trigger));

  assert.doesNotMatch(sql,/create or replace function public\.record_customer_receipt/);
  assert.doesNotMatch(sql,/create or replace function public\.record_supplier_payment/);
  assert.doesNotMatch(sql,/create or replace function public\.allocate_customer_advance/);
  assert.doesNotMatch(sql,/create or replace function public\.allocate_supplier_advance/);
  assert.doesNotMatch(sql,/create or replace function public\.reverse_classified_cash_transaction/);
  assert.doesNotMatch(sql,/create or replace function public\.reverse_advance_allocation/);
});

test("private security-definer integration helpers are not API-callable",()=>{
  for(const fn of[
    "accounting_source_event_in_scope\\(date\\)",
    "accounting_post_source_journal\\(text,text,text,date,text,text,uuid,jsonb,uuid\\)",
    "accounting_reverse_source_journal\\(text,text,text,date,text,uuid\\)",
    "accounting_cash_source_insert_trigger\\(\\)",
    "accounting_cash_source_reversal_trigger\\(\\)",
  ]){
    assert.match(sql,new RegExp("revoke all on function private\\."+fn+" from public,anon,authenticated"));
  }
});

test("integration matrix preserves the staged accounting contract",()=>{
  for(const phrase of[
    "Goods receipt",
    "Supplier invoice approval",
    "Customer receipt — settlement",
    "Supplier payment — settlement",
    "Production completion",
    "Payroll accrual",
    "Daily labor accrual",
    "Rental revenue/customer charge",
    "Opening balance journal",
  ]) assert.ok(matrix.includes(phrase),phrase);
  assert.match(matrix,/project_actual_cost_entries/);
  assert.match(matrix,/Opening balances enter only through explicit opening journals/);
});
