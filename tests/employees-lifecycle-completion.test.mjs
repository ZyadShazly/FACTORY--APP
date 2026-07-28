import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migrationPath = "supabase/migrations/202607280003_employee_lifecycle_completion.sql";
const migration = fs.readFileSync(migrationPath, "utf8");
const employeeWorkflow = fs.readFileSync("supabase/migrations/20260721100000_employee_management_workflow.sql", "utf8");
const employeeDeleteGuard = fs.readFileSync("supabase/migrations/20260721101000_employee_delete_guard_reconcile.sql", "utf8");
const projectIndexes = fs.readFileSync("supabase/migrations/202607190002_project_workspace_performance_hardening.sql", "utf8");
const assetIndexes = fs.readFileSync("supabase/migrations/202607180008_assets_security_performance_hardening.sql", "utf8");
const productionCompletion = fs.readFileSync("supabase/migrations/202607280001_production_pilot_completion.sql", "utf8");
const identityBinding = fs.readFileSync("supabase/migrations/202607180007_bind_asset_employee_profile_identity.sql", "utf8");
const payrollFoundation = fs.readFileSync("supabase/migrations/202607130001_v2_2_projects_payroll.sql", "utf8");
const ui = fs.readFileSync("src/v22/payroll.jsx", "utf8");
const tracker = fs.readFileSync("docs/acceptance/FULL_PILOT_HARDENING_TRACKER.md", "utf8");
const acceptance = fs.readFileSync("docs/acceptance/EMPLOYEES_LIFECYCLE_COMPLETION.md", "utf8");

test("employee completion migration is additive and preserves all employee history", () => {
  assert.match(migration, /create or replace function public\.employee_dependency_summary/);
  assert.doesNotMatch(migration, /\balter table\b|\bdrop table\b|\btruncate\b|\bdelete from\b|\bupdate public\./i);
  assert.doesNotMatch(migration, /create or replace function public\.(delete_employee_if_unused|set_employee_status|update_employee_record)/);
  assert.match(employeeDeleteGuard, /Employees cannot be deleted directly/);
  assert.match(employeeWorkflow, /delete_employee_if_unused/);
  assert.match(employeeWorkflow, /summary := public\.employee_dependency_summary/);
});

test("exact dependency records cover every implemented employee linkage", () => {
  const expected = [
    ["payroll", "employee_id"],
    ["profiles", "employee_id"],
    ["asset_assignments", "receiver_employee_id"],
    ["work_schedules", "employee_id"],
    ["holiday_scopes", "employee_id"],
    ["project_members", "employee_id"],
    ["project_milestones", "responsible_employee_id"],
    ["production_order_operations", "assigned_employee_id"],
  ];
  for (const [table, column] of expected) {
    assert.match(migration, new RegExp(`from public\\.${table}[\\s\\S]*?where [a-z_]+\\.${column} = target_employee_id`, "i"));
  }
  assert.match(migration, /'dependency_records', jsonb_build_object/);
  assert.match(migration, /'id', p\.id[\s\S]*'reference', p\.payroll_month[\s\S]*'advance_amount', p\.advances/);
  assert.match(migration, /'reference', a\.assignment_code/);
  assert.match(migration, /'reference', p\.project_code/);
  assert.match(migration, /'reference', operation\.name/);
});

test("attendance, advances, projects, assets, and external labor are modeled honestly", () => {
  assert.match(migration, /'attendance', 'No standalone attendance ledger exists;/);
  assert.match(migration, /work schedules and holiday scopes are shown/);
  assert.match(migration, /'advances', 'Advances are stored on payroll rows/);
  assert.match(migration, /'external_labor', 'Daily labor has no employee foreign key/);
  assert.match(acceptance, /الحضور[\s\S]*work_schedules[\s\S]*holiday_scopes/);
  assert.match(acceptance, /السلف[\s\S]*payroll\.advances/);
  assert.match(acceptance, /العمالة الخارجية[\s\S]*غير منطبق/);
});

test("every dependency lookup has an existing or newly added covering index", () => {
  assert.match(payrollFoundation, /unique\s*\(\s*employee_id\s*,\s*payroll_month\s*\)/i);
  assert.match(identityBinding, /profiles_employee_id_unique[\s\S]*on public\.profiles\(employee_id\)/i);
  assert.match(assetIndexes, /idx_asset_assignments_receiver_employee_id[\s\S]*asset_assignments\(receiver_employee_id\)/i);
  assert.match(migration, /work_schedules_employee_id_idx[\s\S]*work_schedules\(employee_id\)[\s\S]*where employee_id is not null/i);
  assert.match(migration, /holiday_scopes_employee_id_idx[\s\S]*holiday_scopes\(employee_id\)[\s\S]*where employee_id is not null/i);
  assert.match(projectIndexes, /project_members_employee_idx[\s\S]*project_members\(employee_id\)/i);
  assert.match(payrollFoundation + fs.readFileSync("supabase/migrations/202607190001_project_workspace_upgrade.sql", "utf8"), /project_milestones_responsible_employee_idx[\s\S]*project_milestones\(responsible_employee_id\)/i);
  assert.match(productionCompletion, /production_operations_assigned_employee_idx[\s\S]*production_order_operations\(assigned_employee_id\)/i);
  const names = [...migration.matchAll(/create (?:unique )?index if not exists\s+([a-z0-9_]+)/gi)].map((match) => match[1]);
  assert.equal(new Set(names).size, names.length);
});

test("dependency summary keeps authorization and a fixed search path", () => {
  assert.match(migration, /public\.current_identity_role\(\) not in \('owner', 'manager', 'accountant'\)/);
  assert.match(migration, /security definer\s+set search_path = ''/);
  assert.match(migration, /revoke all on function public\.employee_dependency_summary\(uuid\) from public, anon/);
  assert.match(migration, /grant execute on function public\.employee_dependency_summary\(uuid\) to authenticated/);
  assert.doesNotMatch(migration, /set search_path\s*=\s*public/i);
});

test("employee workspace puts active employees first and keeps archive collapsed", () => {
  assert.match(ui, /const activeEmployees = employees\.filter\(\(employee\) => employee\.status === "active"\)/);
  assert.match(ui, /const archivedEmployees = employees\.filter\(\(employee\) => employee\.status !== "active"\)/);
  assert.match(ui, /<Panel><h3>الموظفون النشطون<\/h3>/);
  assert.match(ui, /<ArchiveSection title="الموظفون المؤرشفون"/);
  assert.doesNotMatch(ui, /<ArchiveSection[^>]*defaultOpen/);
  assert.ok(ui.indexOf("الموظفون النشطون</h3>") < ui.indexOf('ArchiveSection title="الموظفون المؤرشفون"'));
});

test("employee workspace exposes add, edit, archive, restore, and checked delete", () => {
  assert.match(ui, /موظف جديد/);
  assert.match(ui, /تعديل/);
  assert.match(ui, /<PauseCircle size=\{14\}\/> أرشفة/);
  assert.match(ui, /<PlayCircle size=\{14\}\/> استعادة/);
  assert.match(ui, /delete_employee_if_unused/);
  assert.match(ui, /summary\?\.can_delete/);
  assert.match(ui, /سبب الحذف مطلوب/);
});

test("dependency records are visible and raw foreign-key errors are translated", () => {
  assert.match(ui, /summary\?\.dependency_records\?\.\[key\]/);
  assert.match(ui, /record\.label \|\| record\.reference \|\| record\.id/);
  assert.match(ui, /<DependencySummary title="الارتباطات التي تحفظ تاريخ الموظف"/);
  assert.match(ui, /error\?\.code === "23503"/);
  assert.match(ui, /افتح ملف الموظف لمراجعة الارتباطات ثم استخدم الأرشفة/);
  assert.doesNotMatch(ui, /return text\.includes\("foreign key"\) \? text/);
});

test("employee workspace uses no more than five KPIs and keeps one primary action", () => {
  const employeeSection = ui.slice(ui.indexOf("export function EmployeesTab"), ui.indexOf("function EmployeeForm"));
  assert.equal((employeeSection.match(/<KpiCard\b/g) || []).length, 4);
  assert.equal((employeeSection.match(/<UserPlus\b/g) || []).length, 1);
  assert.match(employeeSection, /<SearchFilterBar/);
});

test("phase evidence traces Bug H without claiming unimplemented tables", () => {
  assert.match(tracker, /6 — Employee lifecycle[\s\S]*Bug H/);
  assert.match(acceptance, /Bug H/);
  assert.match(acceptance, /لا توجد جداول مستقلة للحضور أو السلف/);
  assert.match(acceptance, /لم تُطبّق على Supabase/);
});
