import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/202607190013_procurement_workflow.sql', import.meta.url), 'utf8');
const hardening = await readFile(new URL('../supabase/migrations/202607190014_procurement_security_hardening.sql', import.meta.url), 'utf8');
const accounting = await readFile(new URL('../supabase/migrations/202607190015_procurement_invoice_accounting_hardening.sql', import.meta.url), 'utf8');

test('procurement workflow exposes protected lifecycle RPCs', () => {
  for (const rpc of ['save_purchase_request','submit_purchase_request','decide_purchase_request','save_supplier_quote','create_purchase_order_from_quote','confirm_goods_receipt','approve_supplier_invoice','get_procurement_workspace']) {
    assert.match(migration + hardening + accounting, new RegExp(`function public\\.${rpc}`));
  }
});

test('procurement relationships are guarded across request, order, receipt, and invoice', () => {
  assert.match(hardening, /supplier_quote_items_relationship_guard/);
  assert.match(hardening, /goods_receipt_items_relationship_guard/);
  assert.match(hardening, /supplier_invoice_lines_relationship_guard/);
});

test('supplier invoice posts net line total to Actual Cost', () => {
  assert.match(accounting, /line_total_value:=round/);
  assert.match(accounting, /'quantity',1/);
  assert.match(accounting, /'unit_cost',line_total_value/);
  assert.match(accounting, /purchase_invoice_line:/);
});

test('procurement tables are RPC-only for authenticated users', async () => {
  const foundation = await readFile(new URL('../supabase/migrations/202607190012_procurement_foundation.sql', import.meta.url), 'utf8');
  assert.match(foundation, /revoke all on public\.purchase_requests/);
  assert.match(foundation, /from anon,authenticated/);
});
