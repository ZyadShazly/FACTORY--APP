import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/202608041015_uat_procurement_currency_contract.sql', import.meta.url),
  'utf8',
);

test('UAT-006 adds currency conversion metadata without rewriting legacy documents', () => {
  for (const table of ['supplier_quotes', 'purchase_orders', 'supplier_invoices']) {
    assert.match(migration, new RegExp(`alter table public\\.${table}`));
  }
  for (const column of ['base_currency', 'exchange_rate', 'rate_date', 'base_total_amount']) {
    assert.match(migration, new RegExp(`add column if not exists ${column}`));
  }
  assert.doesNotMatch(migration, /update public\.(supplier_quotes|purchase_orders|supplier_invoices)/i);
});

test('UAT-006 requires positive rate metadata when a conversion contract is present', () => {
  assert.match(migration, /exchange_rate is not null and exchange_rate > 0/);
  assert.match(migration, /rate_date is not null/);
  assert.match(migration, /base_total_amount is not null and base_total_amount >= 0/);
});

test('UAT-006 fixes same-currency documents to rate one', () => {
  assert.match(migration, /currency = base_currency and exchange_rate = 1/);
});

test('UAT-006 exposes reconciliation evidence for legacy and incomplete documents', () => {
  assert.match(migration, /create or replace view public\.procurement_currency_reconciliation/);
  assert.match(migration, /missing_conversion_contract/);
  assert.match(migration, /missing_foreign_rate/);
  assert.match(migration, /same_currency_rate_not_one/);
});
