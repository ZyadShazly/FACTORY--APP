import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const component = fs.readFileSync(new URL("../src/reporting/ReportingWorkspace.jsx", import.meta.url), "utf8");
const migration = fs.readFileSync(new URL("../supabase/migrations/202607200007_reporting_analytics_foundation.sql", import.meta.url), "utf8");
const patch = fs.readFileSync(new URL("../scripts/apply-reporting-workspace.mjs", import.meta.url), "utf8");

test("reporting UI uses only the protected workspace RPC", () => {
  assert.match(component, /supabase\.rpc\("get_reporting_workspace"/);
  assert.doesNotMatch(component, /supabase\.from\(/);
  assert.match(component, /Financial reporting access required/);
});

test("reporting migration protects the security definer function", () => {
  assert.match(migration, /security definer/i);
  assert.match(migration, /set search_path = public, private, pg_temp/i);
  assert.match(migration, /actor is null or role_name not in \('owner', 'manager', 'accountant'\)/i);
  assert.match(migration, /revoke all on function public\.get_reporting_workspace\(date, date\) from public, anon/i);
  assert.match(migration, /grant execute on function public\.get_reporting_workspace\(date, date\) to authenticated/i);
});

test("reporting patch is bounded and idempotent", () => {
  assert.match(patch, /Reporting patch boundaries were not found/);
  assert.match(patch, /source\.includes\(importLine\)/);
  assert.match(patch, /function ReportsTab\(\)/);
});
