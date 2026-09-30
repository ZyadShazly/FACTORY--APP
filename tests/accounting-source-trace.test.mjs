import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260930122500_accounting_source_trace.sql",
  "utf8",
);

test("source trace is accounting-view protected and authenticated-only",()=>{
  assert.match(sql,/private\.accounting_permission_allowed\('accounting_view'\)/);
  assert.match(sql,/revoke all on function public\.get_accounting_source_trace\(uuid\) from public,anon/);
  assert.match(sql,/grant execute on function public\.get_accounting_source_trace\(uuid\) to authenticated/);
});

test("source trace resolves reversals through the original journal",()=>{
  assert.match(sql,/requested\.reversal_of_entry_id is not null/);
  assert.match(sql,/where id=requested\.reversal_of_entry_id/);
  assert.match(sql,/'journal_is_reversal'/);
});

test("source trace only reads whitelisted Integration Matrix source tables",()=>{
  for(const table of[
    "asset_settlements","asset_maintenance_orders","customer_adjustments",
    "customer_advance_allocations","customer_receipts","daily_labor","expenses",
    "inventory_movements","payroll","supplier_invoices","production_material_issues",
    "rentals","sales","supplier_payments","supplier_advance_allocations",
  ]) assert.match(sql,new RegExp(`'${table}'`));
  assert.match(sql,/format\([\s\S]*public\.%I/);
  assert.doesNotMatch(sql,/source_journal\.source_module\s*\|\|/);
});

test("manual journals and missing source records fail closed without crashing",()=>{
  assert.match(sql,/Journal has no operational source/);
  assert.match(sql,/Operational source type is not registered for drill-down/);
  assert.match(sql,/Operational source record was not found/);
  assert.match(sql,/'available',source_record is not null/);
});

test("source trace is read-only and does not mutate operational or accounting data",()=>{
  assert.doesNotMatch(sql,/\binsert\s+into\b/i);
  assert.doesNotMatch(sql,/\bupdate\s+public\./i);
  assert.doesNotMatch(sql,/\bdelete\s+from\b/i);
});
