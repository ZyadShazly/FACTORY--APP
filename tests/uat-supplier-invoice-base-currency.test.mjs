import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/202608041115_uat_supplier_invoice_base_currency_posting.sql', import.meta.url),
  'utf8',
);

test('UAT-006 invoice approval preserves document and base currency metadata', () => {
  assert.match(migration, /currency,base_currency,exchange_rate,rate_date,status/);
  assert.match(migration, /effective_base_currency:=coalesce/);
  assert.match(migration, /effective_rate:=coalesce/);
});

test('UAT-006 rejects incomplete or invalid exchange-rate contracts', () => {
  assert.match(migration, /positive exchange rate is required/i);
  assert.match(migration, /Exchange-rate date is required/i);
  assert.match(migration, /Exchange rate must equal 1/i);
});

test('UAT-006 posts project actual cost in base currency and keeps audit metadata', () => {
  assert.match(migration, /base_line_total:=round\(line_total_value\*effective_rate,2\)/);
  assert.match(migration, /'unit_cost',base_line_total/);
  assert.match(migration, /'document_amount',line_total_value/);
  assert.match(migration, /'document_currency',po.currency/);
  assert.match(migration, /'base_amount',base_line_total/);
  assert.match(migration, /'base_currency',effective_base_currency/);
});

test('UAT-006 computes and stores invoice base total without rewriting history', () => {
  assert.match(migration, /base_total_amount=round\(x.total_amount\*effective_rate,2\)/);
  assert.doesNotMatch(migration, /update public\.supplier_invoices\s+set currency/i);
  assert.doesNotMatch(migration, /delete from public\.supplier_invoices/i);
});
