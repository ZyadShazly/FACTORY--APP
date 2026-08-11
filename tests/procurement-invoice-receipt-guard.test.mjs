import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ui=readFileSync("src/operational/ProcurementWorkspace.jsx","utf8");
const migration=readFileSync("supabase/migrations/20260810290000_supplier_invoice_full_receipt_guard.sql","utf8");

test("invoice approval UI only offers fully received purchase orders",()=>{
  assert.match(ui,/invoiceableOrders=ws\.orders\.filter\(row=>row\.status==="fully_received"\)/);
  assert.match(ui,/أمر الشراء المستلم بالكامل/);
  assert.match(ui,/شرط المطابقة/);
});

test("invoice approval is blocked unless all received lines match once",()=>{
  assert.match(migration,/order_row\.status<>'fully_received'/);
  assert.match(migration,/line_count<>1/);
  assert.match(migration,/invoiced_quantity<>poi\.received_quantity/);
  assert.match(migration,/poi\.received_quantity<>poi\.quantity/);
  assert.match(migration,/Purchase order already has an approved supplier invoice/);
  assert.match(migration,/Supplier invoice number already exists/);
  assert.match(migration,/revoke all on function private\.enforce_supplier_invoice_full_receipt\(\) from public,anon,authenticated/i);
});
