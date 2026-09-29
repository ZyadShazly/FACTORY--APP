import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929124359_accounting_rentals_integration.sql",
  "utf8",
);
const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("rental integration posts only active positive-fee rentals",()=>{
  assert.match(sql,/tg_op='INSERT'[\s\S]*new\.status='active'/);
  assert.match(sql,/if amount_base=0 then[\s\S]*return new/);
  assert.match(sql,/private\.accounting_source_event_in_scope\(event_date\)/);
});

test("rental customer charge debits AR and credits mapped rental revenue",()=>{
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'accounts_receivable','global',''/);
  assert.match(sql,/accounting_resolve_mapping\([\s\S]*'rental_revenue','global',''/);
  assert.match(sql,/'account_id',ar_account[\s\S]*'debit',amount_base/);
  assert.match(sql,/'account_id',revenue_account[\s\S]*'credit',amount_base/);
  assert.match(sql,/'partner_type','customer'/);
  assert.match(sql,/'partner_id',new\.customer_id/);
  assert.match(sql,/rental_customer_charge_posted/);
});

test("rental cancellation reverses the source-linked revenue journal",()=>{
  assert.match(sql,/old\.status='active'[\s\S]*new\.status='cancelled'/);
  assert.match(sql,/accounting_reverse_source_journal\([\s\S]*'rentals'[\s\S]*'rental_customer_charge_posted'/);
  assert.match(sql,/new\.cancellation_reason/);
});

test("rental inventory custody does not create sale COGS or inventory accounting",()=>{
  assert.doesNotMatch(sql,/rental_issue/);
  assert.doesNotMatch(sql,/rental_return/);
  assert.doesNotMatch(sql,/\bcogs\b/i);
  assert.doesNotMatch(sql,/accounting_resolve_mapping\([\s\S]*'inventory'/);
  assert.match(matrix,/rental issue\/return remains operational custody only/);
});

test("rental integration keeps existing public RPCs untouched and no historical backfill",()=>{
  assert.doesNotMatch(sql,/create or replace function public\.post_rental/);
  assert.doesNotMatch(sql,/create or replace function public\.cancel_rental/);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\.rentals/i);
});

test("rental trigger is private and has no hard-coded generated account UUIDs",()=>{
  assert.match(sql,/revoke all on function private\.accounting_rental_gl_trigger\(\)[\s\S]*from public,anon,authenticated/);
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("integration matrix marks rentals implemented and leaves assets planned",()=>{
  assert.match(matrix,/Rental customer-charge \/ cancellation integration: implemented\./);
  assert.match(matrix,/All Integration Matrix modules above now have an explicit accounting behavior/);
});
