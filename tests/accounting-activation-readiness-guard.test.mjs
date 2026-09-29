import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260929134408_accounting_activation_readiness_guard.sql",
  "utf8",
);

test("activation still requires an explicit activation date",()=>{
  assert.match(sql,/coalesce\(target_enabled,false\)[\s\S]*target_activation_date is null/);
  assert.match(sql,/Accounting activation date is required before enabling accounting/);
});

test("activation requires every active required mapping to resolve to an active posting account",()=>{
  assert.match(sql,/accounting_mapping_definitions d/);
  assert.match(sql,/d\.required_for_auto_posting/);
  assert.match(sql,/accounting_account_mappings m/);
  assert.match(sql,/a\.is_active/);
  assert.match(sql,/a\.is_posting/);
  assert.match(sql,/Accounting cannot be enabled until all required account mappings are configured/);
  assert.match(sql,/array_to_string\(missing_mappings,', '\)/);
});

test("activation requires an open period covering the activation date",()=>{
  assert.match(sql,/from public\.accounting_periods p/);
  assert.match(sql,/p\.status='open'/);
  assert.match(sql,/target_activation_date between p\.period_start and p\.period_end/);
  assert.match(sql,/Accounting cannot be enabled until an open accounting period covers the activation date/);
});

test("readiness checks only apply when enabling so disabling remains available",()=>{
  const guardIndex=sql.indexOf("if coalesce(target_enabled,false) then");
  const updateIndex=sql.indexOf("update public.accounting_settings");
  assert.ok(guardIndex>=0);
  assert.ok(updateIndex>guardIndex);
  const guarded=sql.slice(guardIndex,updateIndex);
  assert.match(guarded,/missing_mappings/);
  assert.match(guarded,/accounting_periods/);
  assert.match(sql,/set enabled=coalesce\(target_enabled,false\)/);
});

test("existing posted-journal activation date protections are preserved",()=>{
  assert.match(sql,/select min\(entry_date\)[\s\S]*from public\.accounting_journal_entries/);
  assert.match(sql,/Activation date cannot be removed after journals have been posted/);
  assert.match(sql,/Activation date cannot be moved after the earliest posted journal/);
});

test("activation configuration remains owner-only and authenticated-only",()=>{
  assert.match(sql,/public\.current_identity_role\(\)<>'owner'/);
  assert.match(sql,/revoke all on function public\.owner_configure_accounting\(date,boolean\)[\s\S]*from public,anon/);
  assert.match(sql,/grant execute on function public\.owner_configure_accounting\(date,boolean\)[\s\S]*to authenticated/);
});

test("readiness migration does not mutate operational modules or create historical journals",()=>{
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries/i);
  assert.doesNotMatch(sql,/update\s+public\.(sales|expenses|payroll|daily_labor|rentals|assets|inventory_movements|supplier_invoices|customer_receipts)/i);
  assert.doesNotMatch(sql,/insert\s+into\s+public\.(sales|expenses|payroll|daily_labor|rentals|assets|inventory_movements|supplier_invoices|customer_receipts)/i);
});
