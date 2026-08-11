import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const ui=fs.readFileSync("src/reporting/ReportingWorkspace.jsx","utf8");
const migration=fs.readFileSync("supabase/migrations/20260810340000_operational_reporting_summary.sql","utf8");

test("reporting loads the protected period operational summary",()=>{
  assert.match(ui,/get_operational_reporting_summary/);
  assert.match(ui,/النشاط المالي والتجاري داخل الفترة/);
  assert.match(ui,/الرصيد المستحق للموردين/);
  assert.doesNotMatch(ui,/label="فواتير الموردين المستحقة"/);
});

test("operational totals exclude cancelled and non-final financial rows",()=>{
  assert.match(migration,/sale\.status='posted'/i);
  assert.match(migration,/rental\.status<>'cancelled'/i);
  assert.match(migration,/expense\.cancelled_at is null/i);
  assert.match(migration,/payroll\.status in \('approved','paid'\)/i);
  assert.match(migration,/private\.customer_due\(customer\.id\)/i);
  assert.match(migration,/private\.supplier_due\(supplier\.id\)/i);
});

test("operational reporting remains restricted to finance-capable active roles",()=>{
  assert.match(migration,/current_identity_role\(\) not in \('owner','manager','accountant'\)/i);
  assert.match(migration,/is_current_profile_active\(\)/i);
  assert.match(migration,/revoke all on function public\.get_operational_reporting_summary\(date,date\) from public,anon/i);
});
