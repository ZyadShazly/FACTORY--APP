import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ui=readFileSync("src/operational/ProcurementWorkspace.jsx","utf8");
const migration=readFileSync("supabase/migrations/20260810280000_procurement_partial_receipt_integrity.sql","utf8");
const rejectedMigration=readFileSync("supabase/migrations/20260810330000_procurement_rejected_receipt_workflow.sql","utf8");

test("receipt UI captures partial accepted and rejected quantities per order line",()=>{
  assert.match(ui,/receiptLines/);
  assert.match(ui,/الكمية المقبولة/);
  assert.match(ui,/الكمية المرفوضة/);
  assert.match(ui,/تم تسجيل الشحنة المرفوضة دون إضافة رصيد للمخزون/);
  assert.doesNotMatch(ui,/لا يمكن ترحيل إذن بلا كمية مقبولة/);
  assert.match(ui,/condition:rejected>0\?\(accepted>0\?"partially_rejected":"rejected"\):"accepted"/);
  assert.match(ui,/accepted>remaining/);
});

test("fully rejected deliveries are retained without inventory movements",()=>{
  assert.match(rejectedMigration,/receipt_item\.accepted_quantity>0/i);
  assert.match(rejectedMigration,/'inventory_posted',jsonb_array_length\(movements\)>0/i);
  assert.doesNotMatch(rejectedMigration,/Receipt has no accepted inventory quantities/i);
});

test("database serializes receipts and rejects over-receipt or foreign order lines",()=>{
  assert.match(migration,/from public\.purchase_orders where id=po_id for update/i);
  assert.match(migration,/from public\.purchase_order_items where id=item_id and purchase_order_id=po_id for update/i);
  assert.match(migration,/accepted>remaining/);
  assert.match(migration,/accepted>delivered/);
  assert.match(migration,/revoke all on function public\.confirm_goods_receipt\(jsonb\) from public,anon,authenticated/i);
});
