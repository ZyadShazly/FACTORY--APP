import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const payroll = fs.readFileSync(new URL("../src/v22/payroll.jsx", import.meta.url), "utf8");
const migration = fs.readFileSync(new URL("../supabase/migrations/20260721100000_employee_management_workflow.sql", import.meta.url), "utf8");
const guard = fs.readFileSync(new URL("../supabase/migrations/20260721101000_employee_delete_guard_reconcile.sql", import.meta.url), "utf8");
const operationalPatch = fs.readFileSync(new URL("../scripts/apply-operational-bug-closure.mjs", import.meta.url), "utf8");

test("employee list exposes view, edit, suspend and reactivate actions", () => {
  assert.match(payroll, /<Eye size=\{14\}\/?> فتح/);
  assert.match(payroll, /<Pencil size=\{14\}\/?> تعديل/);
  assert.match(payroll, /<PauseCircle size=\{14\}\/?> إيقاف/);
  assert.match(payroll, /<PlayCircle size=\{14\}\/?> تفعيل/);
});

test("employee status changes are separate from login account status", () => {
  assert.match(migration, /'login_account_changed', false/);
  assert.match(payroll, /حساب الدخول لا يتغير تلقائيًا/);
  assert.doesNotMatch(migration, /update\s+public\.profiles\s+set\s+status/i);
});

test("permanent delete requires dependency inspection and a reason", () => {
  assert.match(migration, /employee_dependency_summary/);
  assert.match(migration, /delete_employee_if_unused/);
  assert.match(migration, /سبب الحذف مطلوب/);
  assert.match(migration, /can_delete/);
  assert.match(migration, /profiles where employee_id/);
  assert.match(migration, /payroll where employee_id/);
  assert.match(migration, /asset_assignments where receiver_employee_id/);
});

test("direct employee lifecycle bypass remains blocked", () => {
  assert.match(migration, /enforce_employee_controlled_lifecycle/);
  assert.match(guard, /current_setting\('app\.employee_admin_rpc'/);
  assert.match(guard, /Employees cannot be deleted directly/);
});

test("owner and manager manage employees while accountant remains read-only", () => {
  assert.match(migration, /current_identity_role\(\) in \('owner', 'manager', 'accountant'\)/);
  assert.match(migration, /employee_admin_allowed/);
  assert.match(migration, /current_identity_role\(\) in \('owner', 'manager'\)/);
});

test("prebuild operational patch recognises the new workflow", () => {
  assert.match(operationalPatch, /employee_dependency_summary/);
  assert.match(operationalPatch, /row\.status !== "draft"/);
});
