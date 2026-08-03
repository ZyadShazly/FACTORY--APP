import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration = fs.readFileSync("supabase/migrations/20260803055244_daily_labor_actual_cost_integration.sql", "utf8");
const ui = fs.readFileSync("src/v22/dailyLabor.jsx", "utf8");

test("daily labor posts net settlement with explainable metadata", () => {
  assert.match(migration, /select project_id,net_amount,work_date/);
  assert.match(migration, /1,'يوم',net_amount/);
  for (const field of ["settlement_basis", "gross_amount", "addition_amount", "deduction_amount"]) {
    assert.match(migration, new RegExp(`'${field}'`));
  }
  assert.match(migration, /'settlement_basis','net_amount'/);
});

test("only approved project-linked shifts enter Actual Cost once", () => {
  assert.match(migration, /p_review_status <> 'approved'/);
  assert.match(migration, /Daily labor shift must be approved before Actual Cost submission/);
  assert.match(migration, /coalesce\(p_cost_status,'not_posted'\) <> 'not_posted'/);
  assert.match(migration, /Daily labor shift is already in the Actual Cost workflow/);
  assert.match(migration, /Source must be linked to a project/);
  assert.match(migration, /Source is already linked to an Actual Cost entry/);
  assert.match(migration, /for update/);
});

test("operational sources and daily labor cost fields cannot bypass protected workflows", () => {
  assert.match(migration, /Operational Actual Cost sources must use the protected source workflow/);
  assert.match(migration, /set_config\('app\.operational_actual_cost','on',true\)/);
  assert.match(migration, /Daily labor Actual Cost fields can only change through protected cost workflow/);
  assert.match(migration, /set_config\('app\.daily_labor_actual_cost','on',true\)/);
  assert.ok(migration.indexOf("set_config('app.daily_labor_actual_cost','on',true)") < migration.indexOf("insert into public.project_actual_cost_entries"));
  assert.match(migration, /revoke all on function public\.prepare_operational_source_actual_cost\(text,uuid\)[\s\S]*public,anon,authenticated/);
  assert.match(migration, /revoke all on function private\.sync_operational_source_actual_cost_status\(\)[\s\S]*public,anon,authenticated/);
});

test("daily labor UI submits Actual Cost for finance roles without auto approval", () => {
  assert.match(ui, /prepare_operational_source_actual_cost/);
  assert.match(ui, /target_source_type: "daily_labor"/);
  assert.match(ui, /\["owner", "manager", "accountant"\]/);
  assert.match(ui, /selected\.review_status === "approved"/);
  assert.match(ui, /selected\.project_id/);
  assert.match(ui, /\(selected\.cost_posting_status \|\| "not_posted"\) === "not_posted"/);
  assert.match(ui, /إرسال للتكلفة الفعلية/);
  assert.match(ui, /لا يتم اعتماده أو إضافته لتكلفة المشروع تلقائيًا/);
});

test("integration is additive and preserves all source rows", () => {
  assert.doesNotMatch(migration, /drop table|truncate|delete from public\.daily_labor/i);
  assert.doesNotMatch(migration, /update public\.daily_labor\s+set actual_cost_entry_id=null/i);
});
