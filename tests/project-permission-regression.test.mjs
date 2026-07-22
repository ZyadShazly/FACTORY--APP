import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const mainPermissionMigration = await readFile(new URL("../supabase/migrations/202607180003_assets_tools_foundation.sql", import.meta.url), "utf8");
const projectMigration = await readFile(new URL("../supabase/migrations/202607190001_project_workspace_upgrade.sql", import.meta.url), "utf8");
const sharedFrontend = await readFile(new URL("../src/v22/shared.jsx", import.meta.url), "utf8");
const actionPermissionFrontend = await readFile(new URL("../src/app/actionPermissions.js", import.meta.url), "utf8");
const appFrontend = await readFile(new URL("../src/AppMonolith.jsx", import.meta.url), "utf8");
const permissionFrontend = sharedFrontend + actionPermissionFrontend;

const projectPermissions = [
  "projects_view", "projects_create", "projects_edit", "projects_delete",
  "project_files_view", "project_files_upload", "project_files_delete", "project_financials_view",
  "projects_manage_lifecycle", "projects_manage_milestones", "projects_manage_team",
  "projects_update_progress", "projects_close", "projects_override",
];
const assetPermissions = [
  "assets_view", "assets_create", "assets_edit", "assets_issue", "assets_return", "assets_settle",
  "assets_reports", "assets_settings", "assets_manage", "assets_adjust", "assets_approve_loss",
];
const payrollPermissions = ["payroll_view", "payroll_create", "payroll_edit", "payroll_approve", "payroll_bonus_manage", "payroll_mark_paid"];
const calendarPermissions = ["payroll_calendar_view", "payroll_calendar_manage", "payroll_calendar_approve", "payroll_calendar_stale_override"];
const laborPermissions = ["daily_labor_view", "daily_labor_create", "daily_labor_edit", "daily_labor_delete", "daily_labor_pay"];
const legacyFrontendPermissions = ["can_delete", "view_financials", "can_create_products", "can_edit_products"];
const allPermissions = [...projectPermissions, ...assetPermissions, ...payrollPermissions, ...calendarPermissions, ...laborPermissions, "audit_log_view", ...legacyFrontendPermissions];

const accountantDefaults = new Set([
  "projects_view", "projects_create", "project_financials_view", "project_files_view", "project_files_upload",
  "payroll_view", "payroll_create", "payroll_edit", "payroll_mark_paid",
  "daily_labor_view", "daily_labor_create", "daily_labor_edit", "daily_labor_pay",
]);
const productionAssetPermissions = new Set(["assets_view", "assets_issue", "assets_return"]);
const productionProjectDefaults = new Set(["projects_view", "project_files_view"]);
const productionProjectCustom = new Set(["project_files_upload", "projects_manage_milestones", "projects_update_progress"]);

function mainHasPermission({ role, active = true, stored = {} }, permission) {
  if (!active || !role) return false;
  if (role === "owner" || role === "manager") return true;
  if (role === "accountant") return accountantDefaults.has(permission) || stored[permission] === true;
  if (role === "production") return productionAssetPermissions.has(permission) && stored[permission] === true;
  return false;
}

function projectHasPermission(identity, permission) {
  if (!identity.active || !identity.role) return false;
  if (identity.role === "production") {
    if (productionProjectDefaults.has(permission)) return true;
    if (productionProjectCustom.has(permission)) return identity.stored?.[permission] === true;
  }
  return mainHasPermission(identity, permission);
}

test("Project migration leaves the merged global has_permission definition untouched", () => {
  assert.match(mainPermissionMigration, /create or replace function public\.has_permission\(permission_name text\)/);
  assert.match(mainPermissionMigration, /when 'production' then permission_name=any\(array\['assets_view','assets_issue','assets_return'\]\)/);
  assert.doesNotMatch(projectMigration, /create or replace function public\.has_permission\s*\(/i);
  assert.match(projectMigration, /create or replace function private\.project_has_permission\(permission_name text\)/);
  assert.match(projectMigration, /else public\.has_permission\(permission_name\)/);
});

test("complete permission matrix preserves main behavior for every non-project permission", () => {
  const activeRoles = ["owner", "manager", "accountant", "production"];
  for (const role of activeRoles) {
    const stored = Object.fromEntries(allPermissions.map((permission) => [permission, true]));
    for (const permission of allPermissions.filter((key) => !projectPermissions.includes(key))) {
      assert.equal(projectHasPermission({ role, active: true, stored }, permission), mainHasPermission({ role, active: true, stored }, permission), `${role}:${permission}`);
    }
  }
  for (const permission of allPermissions) {
    assert.equal(projectHasPermission({ role: "owner", active: false, stored: { [permission]: true } }, permission), false);
    assert.equal(projectHasPermission({ role: null, active: false, stored: { [permission]: true } }, permission), false);
  }
});

test("legacy frontend action permissions remain part of the regression matrix", () => {
  for (const permission of legacyFrontendPermissions) {
    assert.match(permissionFrontend + appFrontend, new RegExp(permission));
    assert.equal(projectHasPermission({ role: "accountant", active: true, stored: { [permission]: true } }, permission), true);
    assert.equal(projectHasPermission({ role: "production", active: true, stored: { [permission]: true } }, permission), false);
  }
});

test("Production receives only the intentional membership-scoped project extension", () => {
  const none = { role: "production", active: true, stored: {} };
  const allStored = { role: "production", active: true, stored: Object.fromEntries(allPermissions.map((permission) => [permission, true])) };
  for (const permission of projectPermissions) {
    assert.equal(projectHasPermission(none, permission), productionProjectDefaults.has(permission), `default:${permission}`);
    assert.equal(projectHasPermission(allStored, permission), productionProjectDefaults.has(permission) || productionProjectCustom.has(permission), `custom:${permission}`);
  }
  assert.match(projectMigration, /private\.project_has_permission\('projects_view'\) and exists\(/);
  assert.match(projectMigration, /pm\.start_date is null or pm\.start_date <= current_date/);
  assert.match(projectMigration, /pm\.end_date is null or pm\.end_date >= current_date/);
});

test("accountant defaults and custom permissions remain exactly as merged main", () => {
  for (const permission of allPermissions) {
    assert.equal(mainHasPermission({ role: "accountant", stored: {} }, permission), accountantDefaults.has(permission), permission);
    assert.equal(mainHasPermission({ role: "accountant", stored: { [permission]: true } }, permission), true, permission);
  }
});

test("asset aliases requested for verification are not silently treated as existing operational keys", () => {
  for (const permission of ["assets_create", "assets_edit", "assets_settle", "assets_settings"]) {
    assert.doesNotMatch(actionPermissionFrontend, new RegExp(`"${permission}"`));
    assert.equal(mainHasPermission({ role: "production", stored: { [permission]: true } }, permission), false);
    assert.equal(mainHasPermission({ role: "accountant", stored: { [permission]: true } }, permission), true);
  }
  for (const permission of ["assets_view", "assets_manage", "assets_issue", "assets_return", "assets_adjust", "assets_approve_loss", "assets_reports"]) {
    assert.match(actionPermissionFrontend, new RegExp(`"${permission}"`));
  }
});

test("business RPC grants and internal helper revokes are explicit", () => {
  const businessRpcs = [
    "get_projects_visible()", "project_activation_readiness(uuid)", "create_project_draft(jsonb)",
    "update_project_details(uuid,jsonb)", "transition_project_lifecycle(uuid,text,text)",
    "update_project_execution_stage(uuid,text,text)", "update_project_progress(uuid,text,numeric,text)",
    "save_project_milestone(jsonb)", "remove_project_milestone(uuid,text)",
    "add_project_member(uuid,uuid,uuid,text,date,date)", "update_project_member(uuid,text,boolean,date,date)",
    "remove_project_member(uuid)", "archive_or_cancel_project(uuid,text)",
  ];
  for (const signature of businessRpcs) {
    const escaped = signature.replace(/[()]/g, (character) => `\\${character}`);
    assert.match(projectMigration, new RegExp(`revoke all on function public\\.${escaped} from public, anon;`));
    assert.match(projectMigration, new RegExp(`grant execute on function public\\.${escaped} to authenticated;`));
  }
  assert.match(projectMigration, /revoke all on table public\.projects from anon, authenticated/);
  assert.match(projectMigration, /revoke all on table public\.project_milestones from anon/);
  assert.match(projectMigration, /revoke all on table public\.project_members from anon/);
});