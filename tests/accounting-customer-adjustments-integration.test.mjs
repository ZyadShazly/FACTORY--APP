import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260930072000_accounting_customer_adjustments_integration.sql",
  "utf8",
);
const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("customer adjustment integration is activation-gated and has no backfill",()=>{
  assert.match(sql,/accounting_source_event_in_scope\(event_date\)/);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\.customer_adjustments/i);
  assert.doesNotMatch(sql,/update\s+public\.customer_adjustments/i);
});

test("each supported customer adjustment type has a configurable mapping",()=>{
  for(const key of[
    "customer_adjustment_commercial_discount",
    "customer_adjustment_withholding_tax",
    "customer_adjustment_retention",
    "customer_adjustment_bank_charge",
    "customer_adjustment_other",
  ]) assert.match(sql,new RegExp(`'${key}'`));
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("posted adjustment debits mapped adjustment account and credits receivable",()=>{
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'accounts_receivable'/);
  assert.match(sql,/'account_id',adjustment_account[\s\S]*'debit',amount_base/);
  assert.match(sql,/'account_id',ar_account[\s\S]*'credit',amount_base/);
  assert.match(sql,/'partner_type','customer'/);
  assert.match(sql,/customer_adjustment_posted/);
});

test("adjustment reversal follows the current source-linked journal",()=>{
  assert.match(sql,/old\.status='posted'[\s\S]*new\.status='reversed'/);
  assert.match(sql,/accounting_reverse_source_journal\([\s\S]*'customers'[\s\S]*'customer_adjustment_posted'/);
});

test("customer adjustment trigger is private and public source RPCs stay untouched",()=>{
  assert.match(sql,/revoke all on function private\.accounting_customer_adjustment_gl_trigger\(\)[\s\S]*from public,anon,authenticated/);
  assert.doesNotMatch(sql,/create or replace function public\.record_customer_adjustment/);
  assert.doesNotMatch(sql,/create or replace function public\.reverse_customer_adjustment/);
});

test("matrix states the current adjustment direction explicitly",()=>{
  assert.match(matrix,/Non-cash customer adjustment \(current source always reduces AR\)/);
  assert.match(matrix,/Mapped adjustment account by adjustment type \| Accounts Receivable/);
});


test("deployment prepares required accounts and mappings before installing the trigger",()=>{
  for(const code of["4.4","1.1.09","1.1.10"]){
    assert.match(sql,new RegExp(`'${code}'`));
  }
  for(const key of[
    "customer_adjustment_commercial_discount",
    "customer_adjustment_withholding_tax",
    "customer_adjustment_retention",
    "customer_adjustment_bank_charge",
    "customer_adjustment_other",
  ]){
    assert.match(sql,new RegExp(`'${key}'`));
  }
  assert.match(sql,/Customer adjustment accounting mapping is missing or invalid/);
  assert.ok(
    sql.indexOf("insert into public.accounting_account_mappings")
      < sql.indexOf("create or replace function private.accounting_customer_adjustment_gl_trigger"),
  );
});
