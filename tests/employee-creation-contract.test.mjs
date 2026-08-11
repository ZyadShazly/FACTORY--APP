import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/20260810270000_employee_creation_contract.sql", "utf8");
const ui = readFileSync("src/v22/payroll.jsx", "utf8");

test("employee creation is an idempotent owner-manager command", () => {
  assert.match(migration, /create or replace function public\.create_employee_record/);
  assert.match(migration, /public\.employee_admin_allowed\(\)/);
  assert.match(migration, /employees_command_uidx/);
  assert.match(migration, /public\.normalize_employee_phone/);
  assert.match(migration, /'employee_created'/);
  assert.match(migration, /revoke insert,update,delete on table public\.employees from anon,authenticated/);
});

test("active employee screen uses protected retry-safe creation", () => {
  const activeScreen = ui.slice(0, ui.indexOf("const initialPayroll"));
  assert.match(activeScreen, /supabase\.rpc\("create_employee_record"/);
  assert.match(activeScreen, /\.eq\("command_id", commandId\)/);
  assert.doesNotMatch(activeScreen, /supabase\.from\("employees"\)\.insert/);
});
