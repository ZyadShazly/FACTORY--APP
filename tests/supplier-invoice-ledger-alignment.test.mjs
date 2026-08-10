import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { supplierBalances } from "../src/domain/commercialBalances.js";

const migration=readFileSync("supabase/migrations/202608103000_supplier_invoice_ledger_alignment.sql","utf8");
const ui=readFileSync("src/AppMonolith.jsx","utf8");

test("supplier balance includes approved invoices and preserves legacy direct purchases",()=>{
  const data={materialPurchases:[{supplier_id:"s",qty:2,unit_cost:25}],supplierInvoices:[{supplier_id:"s",status:"approved",total_amount:100},{supplier_id:"s",status:"cancelled",total_amount:999}],supplierPayments:[{supplier_id:"s",status:"posted",amount:40,transaction_classification:"settlement",settlement_amount:40,allocated_advance_amount:0,advance_amount:0}]};
  assert.deepEqual(supplierBalances("s",data),{due:110,advance:0,cashPaid:40,legacyUnclassified:0});
  assert.match(migration,/sum\(si\.total_amount\)[\s\S]*si\.status in \('approved','paid'\)/);
});

test("supplier ledger loads protected invoice summaries and displays them",()=>{
  assert.match(ui,/supabase\.rpc\("get_supplier_invoices_visible"\)/);
  assert.match(ui,/type: "فاتورة مورد"/);
  assert.match(migration,/current_identity_role\(\) not in \('owner','manager','accountant'\)/);
  assert.match(migration,/revoke all on function public\.get_supplier_invoices_visible\(\) from public,anon,authenticated/i);
});
