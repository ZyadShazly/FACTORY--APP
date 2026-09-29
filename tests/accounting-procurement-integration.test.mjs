import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929081000_accounting_procurement_integration.sql",
  "utf8",
);
const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("procurement integration remains activation-gated and does not backfill",()=>{
  assert.match(sql,/private\.accounting_source_event_in_scope\(event_date\)/);
  assert.match(sql,/private\.accounting_source_event_in_scope\(new\.invoice_date\)/);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\.(inventory_movements|supplier_invoices)/i);
  assert.match(matrix,/No historical operational row is auto-posted/);
});

test("goods receipt inventory movement posts inventory against GRNI",()=>{
  assert.match(sql,/new\.movement_type='receipt'/);
  assert.match(sql,/new\.goods_receipt_item_id is not null/);
  assert.match(sql,/accounting_resolve_mapping\('inventory'/);
  assert.match(sql,/accounting_resolve_mapping\('grni'/);
  assert.match(sql,/'account_id',inventory_account,[\s\S]*'debit',base_amount,[\s\S]*'credit',0/);
  assert.match(sql,/'account_id',grni_account,[\s\S]*'debit',0,[\s\S]*'credit',base_amount/);
  assert.match(sql,/'goods_receipt_inventory_posted'/);
});

test("receipt posting preserves base-currency and foreign-currency evidence",()=>{
  assert.match(sql,/source\.base_currency[\s\S]*gl_base_currency/);
  assert.match(sql,/source\.exchange_rate[\s\S]*<=0/);
  assert.match(sql,/base_amount:=round\(document_amount\*source\.exchange_rate,2\)/);
  assert.match(sql,/'transaction_currency',upper\(source\.currency\)/);
  assert.match(sql,/'foreign_amount',document_amount/);
  assert.match(sql,/'exchange_rate',source\.exchange_rate/);
});

test("supplier invoice clears GRNI, records VAT and posts AP",()=>{
  assert.match(sql,/new\.status='approved'/);
  assert.match(sql,/accounting_resolve_mapping\('accounts_payable'/);
  assert.match(sql,/accounting_resolve_mapping\('vat_input'/);
  assert.match(sql,/total_grni_base/);
  assert.match(sql,/total_tax_base/);
  assert.match(sql,/'account_id',grni_account,[\s\S]*'debit',receipt_base_amount/);
  assert.match(sql,/'account_id',vat_account,[\s\S]*'debit',line_tax_base/);
  assert.match(sql,/'account_id',ap_account,[\s\S]*'credit',ap_base_amount/);
  assert.match(sql,/'supplier_invoice_approved'/);
});

test("supplier invoice variance uses configurable purchase price variance mapping",()=>{
  assert.match(sql,/'purchase_price_variance'/);
  assert.match(sql,/array\['expense','cost_of_sales'\]::text\[\]/);
  assert.match(sql,/variance_base_amount:=round\(ap_base_amount-total_grni_base-total_tax_base,2\)/);
  assert.match(sql,/case when variance_base_amount>0 then variance_base_amount else 0 end/);
  assert.match(sql,/case when variance_base_amount<0 then abs\(variance_base_amount\) else 0 end/);
  assert.doesNotMatch(sql,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
});

test("receipt reversal is source-driven and protected after invoice approval",()=>{
  assert.match(sql,/new\.movement_type='receipt_reversal'/);
  assert.match(sql,/supplier_invoices si[\s\S]*si\.status in \('approved','paid'\)/);
  assert.match(sql,/Reverse the approved supplier invoice before reversing this accounted goods receipt/);
  assert.match(sql,/private\.accounting_reverse_source_journal\([\s\S]*'goods_receipt_inventory_posted'/);
});

test("supplier invoice cancellation or reversal reverses linked system journal",()=>{
  assert.match(sql,/old\.status in \('approved','paid'\)/);
  assert.match(sql,/new\.status in \('cancelled','reversed'\)/);
  assert.match(sql,/private\.accounting_reverse_source_journal\([\s\S]*'supplier_invoice_approved'/);
});

test("procurement integration hooks canonical tables without replacing existing RPCs",()=>{
  assert.match(sql,/create trigger accounting_procurement_inventory_gl[\s\S]*on public\.inventory_movements/);
  assert.match(sql,/create trigger accounting_supplier_invoice_gl[\s\S]*on public\.supplier_invoices/);
  assert.doesNotMatch(sql,/create or replace function public\.confirm_goods_receipt/);
  assert.doesNotMatch(sql,/create or replace function public\.confirm_goods_receipt_to_inventory/);
  assert.doesNotMatch(sql,/create or replace function public\.post_goods_receipt_to_inventory/);
  assert.doesNotMatch(sql,/create or replace function public\.approve_supplier_invoice/);
});

test("private procurement trigger helpers are not API-callable",()=>{
  assert.match(sql,/revoke all on function private\.accounting_procurement_inventory_gl_trigger\(\)\s+from public,anon,authenticated/);
  assert.match(sql,/revoke all on function private\.accounting_supplier_invoice_gl_trigger\(\)\s+from public,anon,authenticated/);
});

test("matrix keeps procurement source and no-double-post contract",()=>{
  assert.match(matrix,/Goods receipt/);
  assert.match(matrix,/Supplier invoice approval/);
  assert.match(matrix,/Inventory \/ received asset/);
  assert.match(matrix,/GRNI/);
  assert.match(matrix,/VAT Input/);
  assert.match(matrix,/project_actual_cost_entries/);
  assert.match(matrix,/must not double-post an already-accounted event/);
});
