import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync("supabase/migrations/20260803071500_commercial_transaction_lifecycle.sql","utf8");
const ui=fs.readFileSync("src/AppMonolith.jsx","utf8");

test("sales and rentals preserve immutable history",()=>{
  assert.match(migration,/Sale history cannot be deleted; use cancel_sale/);
  assert.match(migration,/Rental history cannot be deleted; use the rental lifecycle actions/);
  assert.match(migration,/Posted sale is immutable; cancel it and record a corrected sale/);
  assert.match(migration,/Active rental terms are immutable; cancel it and record a corrected rental/);
  assert.match(migration,/drop policy if exists sales_update_permission/);
  assert.match(migration,/drop policy if exists rentals_update_permission/);
  assert.match(migration,/revoke update,delete on table public\.sales from anon,authenticated/);
  assert.match(migration,/revoke update,delete on table public\.rentals from anon,authenticated/);
});

test("protected lifecycle functions are fixed-path and authenticated only",()=>{
  for(const signature of ["cancel_sale\\(uuid,text\\)","mark_rental_returned\\(uuid,date\\)","cancel_rental\\(uuid,text\\)"]){
    assert.match(migration,new RegExp(`revoke all on function public\\.${signature} from public,anon,authenticated`));
    assert.match(migration,new RegExp(`grant execute on function public\\.${signature} to authenticated`));
  }
  assert.equal((migration.match(/security definer set search_path=''/g)||[]).length>=5,true);
  assert.match(migration,/Cancellation reason is required/);
});

test("new invalid financial rows are blocked without rewriting the legacy anomaly",()=>{
  assert.match(migration,/sales_positive_amounts_check[\s\S]*not valid/);
  assert.match(migration,/sales_total_consistency_check[\s\S]*not valid/);
  assert.match(migration,/sales_positive_amounts_check check \(status='cancelled' or/);
  assert.match(migration,/rentals_positive_amounts_check[\s\S]*not valid/);
  assert.doesNotMatch(migration,/update public\.sales set (?:qty|unit_price|total)/i);
  assert.doesNotMatch(migration,/delete from public\.(?:sales|rentals)/i);
});

test("UI excludes cancelled transactions from balances and stock and keeps audit history",()=>{
  assert.match(ui,/data\.sales\.filter\(\(s\) => s\.product_id === productId && s\.status !== "cancelled"\)/);
  assert.match(ui,/data\.sales\.filter\(\(s\) => s\.customer_id === customerId && s\.status !== "cancelled"\)/);
  assert.match(ui,/data\.rentals\.filter\(\(r\) => r\.customer_id === customerId && r\.status !== "cancelled"\)/);
  assert.match(ui,/ArchiveSection title="المبيعات الملغاة"/);
  assert.match(ui,/ArchiveSection title="سجل الإيجارات المكتملة والملغاة"/);
  assert.match(ui,/supabase\.rpc\("cancel_sale"/);
  assert.match(ui,/supabase\.rpc\("mark_rental_returned"/);
  assert.match(ui,/supabase\.rpc\("cancel_rental"/);
  assert.doesNotMatch(ui,/deleteRow\("(?:sales|rentals)"/);
});
