import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const ui = fs.readFileSync("src/v22/PayrollReviewTab.jsx", "utf8");
const css = fs.readFileSync("src/v22/payroll.css", "utf8");
const migration = fs.readFileSync("supabase/migrations/202607280004_payroll_pilot_completion.sql", "utf8");
const docs = fs.readFileSync("docs/acceptance/PAYROLL_PILOT_COMPLETION.md", "utf8");

test("migration is additive and preserves the existing payroll formula and data", () => {
  assert.match(migration, /add column if not exists scheduled_work_days/);
  assert.match(migration, /add column if not exists attendance_reviewed_by uuid references public\.profiles/);
  assert.doesNotMatch(migration, /\b(?:delete from|truncate|drop table|alter column net_salary|generated always as)\b/i);
  assert.match(docs, /does not change the existing generated payroll formula/);
});

test("review derives schedule evidence from the approved calendar without inventing attendance", () => {
  assert.match(migration, /public\.resolve_work_calendar/);
  assert.match(migration, /count\(\*\) filter\(where c\.required_minutes>0\)/);
  assert.match(migration, /Attendance days are required/);
  assert.match(migration, /Attendance and absence must equal scheduled work days/);
  assert.match(migration, /attendance_source_value is null/);
});

test("server-side approval blocks incomplete evidence and stale calendar data", () => {
  for (const contract of [
    "scheduled_work_days is null", "attended_days is null", "absence_days is null",
    "attendance_source", "calendar_stale", "Payroll review details are incomplete",
  ]) assert.match(migration, new RegExp(contract));
  assert.match(migration, /private\.payroll_review_blockers\(target_payroll_id\)/);
  assert.match(migration, /jsonb_array_length\(blockers\)>0/);
});

test("approval rejection and payment are permission-safe protected workflows", () => {
  assert.match(migration, /public\.has_permission\('payroll_approve'\)/);
  assert.match(migration, /public\.has_permission\('payroll_mark_paid'\)/);
  assert.match(migration, /create or replace function public\.mark_payroll_paid/);
  assert.match(migration, /Use protected payroll workflow/);
  assert.match(migration, /Finalized payroll review is immutable/);
  assert.match(migration, /set_config\('app\.payroll_workflow_rpc','on',true\)/);
  assert.match(ui, /supabase\.rpc\("mark_payroll_paid"/);
  assert.doesNotMatch(ui, /\.from\("payroll"\)\.update\(\{status:"paid"\}\)/);
});

test("security-definer entry points use fixed search paths and explicit grants", () => {
  const fixedPaths = migration.match(/set search_path = ''/g) || [];
  assert.ok(fixedPaths.length >= 7);
  for (const signature of [
    "get_payroll_review_snapshot\\(uuid\\)", "update_payroll_review\\(uuid,jsonb\\)",
    "review_payroll\\(uuid,boolean,text\\)", "mark_payroll_paid\\(uuid\\)",
  ]) {
    assert.match(migration, new RegExp(`revoke all on function public\\.${signature} from public, anon`));
  }
  assert.match(migration, /revoke all on function private\.payroll_review_blockers\(uuid\) from public, anon, authenticated/);
});

test("every added payroll actor FK has a unique covering index name", () => {
  const indexes = [...migration.matchAll(/create index if not exists (\w+) on public\.payroll\((\w+)\)/g)];
  const names = indexes.map((match) => match[1]);
  assert.equal(new Set(names).size, names.length);
  assert.ok(indexes.some((match) => match[2] === "attendance_reviewed_by"));
  for (const actor of ["created_by", "approved_by", "rejected_by", "review_updated_by", "calendar_recalculated_by", "calendar_stale_acknowledged_by"]) {
    assert.ok(indexes.some((match) => match[2] === actor), `${actor} needs a covering index`);
  }
});

test("employee drawer exposes all required values and the source for every number", () => {
  assert.match(ui, /DetailsDrawer/);
  for (const label of ["أيام العمل", "أيام الحضور", "أيام الغياب", "العمل الإضافي", "السلفة\/القسط", "الخصومات", "سبب الخصم", "المكافآت", "إجمالي الراتب", "صافي الراتب"]) {
    assert.match(ui, new RegExp(label));
  }
  assert.match(ui, /المصدر:/);
  assert.match(ui, /get_payroll_review_snapshot/);
  assert.match(ui, /disabled=\{busy \|\| loading \|\| !ready\}/);
});

test("active payroll stays first and finalized cycles remain collapsed", () => {
  assert.match(ui, /const activeRows/);
  assert.match(ui, /المسيرات النشطة/);
  assert.match(ui, /ArchiveSection title="المسيرات المعتمدة والمدفوعة"/);
  assert.equal((ui.match(/<KpiCard/g) || []).length, 4);
  assert.match(ui, /actions=\{<PermissionGuard allow=\{permissions\.payroll_create\}>/);
});

test("mobile RTL styling keeps review values in one column", () => {
  assert.match(css, /@media\(max-width:640px\)/);
  assert.match(css, /\.nui-details-drawer \.v22-form-grid\{grid-template-columns:1fr\}/);
  assert.match(docs, /Desktop and mobile RTL acceptance/);
});
