import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync(
  "supabase/migrations/20260928193501_accounting_period_controls.sql",
  "utf8",
);

test("accounting period ranges cannot overlap",()=>{
  assert.match(migration,/accounting_guard_period_overlap/);
  assert.match(migration,/daterange\(p\.period_start,p\.period_end,'\[\]'\) && daterange\(new\.period_start,new\.period_end,'\[\]'\)/);
  assert.match(migration,/Accounting periods cannot overlap/);
});

test("only Owner can configure accounting and periods",()=>{
  assert.match(migration,/Owner role required to configure accounting/);
  assert.match(migration,/Owner role required to manage accounting periods/);
  assert.match(migration,/public\.current_identity_role\(\)<>'owner'/);
});

test("activation date remains protected after posted journals exist",()=>{
  assert.match(migration,/min\(entry_date\)/);
  assert.match(migration,/Activation date cannot be removed after journals have been posted/);
  assert.match(migration,/Activation date cannot be moved after the earliest posted journal/);
});

test("period lifecycle is open, lock and documented reopen",()=>{
  assert.match(migration,/accounting_period_created/);
  assert.match(migration,/accounting_period_locked/);
  assert.match(migration,/accounting_period_reopened/);
  assert.match(migration,/Period lock reason is required/);
  assert.match(migration,/Period reopen reason is required/);
});

test("period and activation RPCs are authenticated-only API surfaces",()=>{
  for(const fn of [
    "owner_configure_accounting\\(date,boolean\\)",
    "owner_create_accounting_period\\(date,date\\)",
    "owner_lock_accounting_period\\(uuid,text\\)",
    "owner_reopen_accounting_period\\(uuid,text\\)",
  ]){
    assert.match(migration,new RegExp(`revoke all on function public\\.${fn} from public,anon`));
    assert.match(migration,new RegExp(`grant execute on function public\\.${fn} to authenticated`));
  }
});

test("period controls do not mutate historical operational modules",()=>{
  assert.doesNotMatch(migration,/drop\s+table/i);
  assert.doesNotMatch(migration,/truncate\s+/i);
  assert.doesNotMatch(migration,/alter\s+table\s+public\.(sales|expenses|supplier_invoices|inventory_movements|payroll|daily_labor)/i);
  assert.doesNotMatch(migration,/update\s+public\.(sales|expenses|supplier_invoices|inventory_movements|payroll|daily_labor)/i);
});
