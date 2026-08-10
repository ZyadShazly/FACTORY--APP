import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/202608102500_workforce_draft_contract.sql", "utf8");
const payroll = readFileSync("src/v22/PayrollReviewTab.jsx", "utf8");
const labor = readFileSync("src/v22/dailyLabor.jsx", "utf8");

test("workforce drafts use idempotent audited database commands", () => {
  assert.match(migration, /payroll_command_uidx/);
  assert.match(migration, /daily_labor_command_uidx/);
  assert.match(migration, /create or replace function public\.create_payroll_draft/);
  assert.match(migration, /salary_source','employee_master_snapshot'/);
  assert.match(migration, /create or replace function public\.create_daily_labor_draft/);
  assert.match(migration, /'daily_labor_draft_created'/);
  assert.match(migration, /revoke insert,update,delete on table public\.payroll,public\.daily_labor from anon,authenticated/);
});

test("payroll draft UI derives salary server-side and verifies retry state", () => {
  assert.match(payroll, /supabase\.rpc\("create_payroll_draft"/);
  assert.match(payroll, /\.eq\("command_id", commandId\)/);
  assert.match(payroll, /supabase\.rpc\("delete_payroll_draft"/);
  assert.doesNotMatch(payroll, /supabase\.from\("payroll"\)\.insert/);
  assert.doesNotMatch(payroll, /window\.confirm|window\.prompt/);
});

test("external labor draft UI delegates calculations and protected deletion", () => {
  assert.match(labor, /supabase\.rpc\("create_daily_labor_draft"/);
  assert.match(labor, /\.eq\("command_id", commandId\)/);
  assert.match(labor, /supabase\.rpc\("delete_daily_labor_draft"/);
  assert.doesNotMatch(labor, /total_hours: calculation\.totalHours/);
  assert.doesNotMatch(labor, /supabase\.from\("daily_labor"\)\.insert/);
  assert.doesNotMatch(labor, /window\.confirm|window\.prompt/);
});
