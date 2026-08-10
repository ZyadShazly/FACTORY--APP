import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const migration = fs.readFileSync("supabase/migrations/202608101900_project_base_currency_contract.sql", "utf8");
const app = fs.readFileSync("src/AppMonolith.jsx", "utf8");
const budget = fs.readFileSync("src/v22/projectBudget.jsx", "utf8");
const workbook = fs.readFileSync("src/reporting/excelWorkbook.js", "utf8");
const reporting = fs.readFileSync("src/reporting/ReportingWorkspace.jsx", "utf8");

test("new project monetary records use the configured base currency", () => {
  assert.match(migration, /create or replace function private\.current_base_currency\(\)/);
  assert.match(migration, /from public\.system_settings where id = true/);
  assert.match(migration, /values\(target_project, next_version, base_currency/);
  assert.match(migration, /base_currency, target_date/);
  assert.match(migration, /enforce_project_budget_base_currency/);
  assert.match(migration, /enforce_project_actual_cost_base_currency/);
});

test("mixed project currencies are rejected rather than silently converted", () => {
  assert.match(migration, /requested_currency is not null and requested_currency <> base_currency/g);
  assert.match(migration, /must match the configured base currency/);
  assert.match(migration, /Historical actual cost currency differs/);
  assert.doesNotMatch(migration, /update public\.project_budget_versions set currency/i);
  assert.doesNotMatch(migration, /update public\.project_actual_cost_entries set currency/i);
});

test("historical mismatches remain visible to an owner-only reconciliation RPC", () => {
  assert.match(migration, /create or replace function public\.get_project_currency_reconciliation\(\)/);
  assert.match(migration, /role = 'owner' and status = 'active'/);
  assert.match(migration, /budget_mismatch_count/);
  assert.match(migration, /actual_cost_mismatch_count/);
  assert.match(migration, /revoke all on function public\.get_project_currency_reconciliation\(\) from public, anon, authenticated/);
});

test("base currency code is frozen once monetary history exists", () => {
  assert.match(migration, /create trigger protect_system_base_currency/);
  assert.match(migration, /new\.currency_code is distinct from old\.currency_code/);
  assert.match(migration, /Base currency cannot be changed after monetary history exists/);
});

test("the app bootstraps currency globally and project budgets do not hardcode SAR", () => {
  assert.match(app, /supabase\.rpc\("get_system_settings"\)/);
  assert.match(app, /configureCurrency\(settings \|\| \{\}\)/);
  assert.match(app, /formatMoney\(stats\.todaySales\)/);
  assert.doesNotMatch(budget, /currency_code:"SAR"/);
  assert.doesNotMatch(budget, /currency="SAR"/);
  assert.doesNotMatch(reporting, /currency\?\.code \|\| "SAR"/);
});

test("Excel currency cells do not mislabel values as Saudi Riyal", () => {
  assert.doesNotMatch(workbook, /ر\.س|ar-SA/);
  assert.match(workbook, /ss:ID="CurrencyTotal"[\s\S]*ss:Format="#,##0\.00"/);
});
