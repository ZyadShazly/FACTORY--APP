import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { customerBalances, supplierBalances, transactionClassLabel } from "../src/domain/commercialBalances.js";

const migration = fs.readFileSync("supabase/migrations/202608101210_uat_customer_supplier_advances.sql", "utf8");
const app = fs.readFileSync("src/AppMonolith.jsx", "utf8");

test("UAT-004 separates customer due, advance, mixed settlement and legacy evidence", () => {
  const data = { sales:[{customer_id:"c",total:100,status:"posted"}],rentals:[],customerReceipts:[
    {customer_id:"c",amount:120,transaction_classification:"mixed",settlement_amount:100,advance_amount:20,allocated_advance_amount:5,status:"posted"},
    {customer_id:"c",amount:1,transaction_classification:null,status:"posted"},
  ] };
  assert.deepEqual(customerBalances("c",data),{due:0,advance:15,cashReceived:121,legacyUnclassified:1});
  assert.equal(transactionClassLabel(data.customerReceipts[0]),"تسوية + سلفة");
  assert.match(migration,/record_customer_receipt/);
  assert.match(migration,/allocate_customer_advance/);
});

test("UAT-005 separates supplier due and advance", () => {
  const data={materialPurchases:[{supplier_id:"s",qty:2,unit_cost:50}],supplierPayments:[{supplier_id:"s",amount:140,transaction_classification:"mixed",settlement_amount:100,advance_amount:40,allocated_advance_amount:10,status:"posted"}]};
  assert.deepEqual(supplierBalances("s",data),{due:0,advance:30,cashPaid:140,legacyUnclassified:0});
  assert.match(migration,/record_supplier_payment/);
  assert.match(migration,/allocate_supplier_advance/);
});

test("new cash rows are RPC-only, idempotent, audited and reversible",()=>{
  assert.match(migration,/Use the protected classified payment workflow/);
  assert.match(migration,/command_id uuid not null unique/);
  assert.match(migration,/Posted cash history cannot be deleted; use reversal/);
  assert.match(migration,/reverse_classified_cash_transaction/);
  assert.match(migration,/reverse_advance_allocation/);
  assert.match(migration,/customer_receipt_classified/);
  assert.match(migration,/supplier_payment_classified/);
  assert.match(app,/supabase\.rpc\("record_customer_receipt"/);
  assert.match(app,/supabase\.rpc\("record_supplier_payment"/);
  assert.doesNotMatch(app,/insertRow\("customerReceipts"/);
  assert.doesNotMatch(app,/insertRow\("supplierPayments"/);
});
