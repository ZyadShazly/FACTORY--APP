import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  canAdministerTarget,
  canAssignRole,
  identityProtectionReason,
  isAdministrativeRole,
  PRODUCTION_ALLOWED_PAGES,
  SELF_SIGNUP_ROLES,
  SYSTEM_ROLES,
} from "../src/identity.js";
import { dataTableKeysForRole, resolveAllowedTab, TABLES } from "../src/realtime.js";

const migrationUrl = new URL("../supabase/migrations/202607150003_owner_identity_security.sql", import.meta.url);
const hierarchyMigrationUrl = new URL("../supabase/migrations/202607160001_enforce_owner_manager_hierarchy.sql", import.meta.url);
const priorMigrationUrl = new URL("../supabase/migrations/202607150002_enforce_protected_role_creation.sql", import.meta.url);
const bootstrapUrl = new URL("../supabase/scripts/promote_existing_user_to_owner.sql", import.meta.url);

test("the product exposes exactly the approved four roles", () => {
  assert.deepEqual(Object.keys(SYSTEM_ROLES), ["owner", "manager", "accountant", "production"]);
  assert.deepEqual([...SELF_SIGNUP_ROLES], ["accountant", "production"]);
  assert.equal(isAdministrativeRole("owner"), true);
  assert.equal(isAdministrativeRole("manager"), true);
  assert.equal(isAdministrativeRole("accountant"), false);
});

test("manager versus owner UI hierarchy blocks protected edits", () => {
  const owner = { id: "owner-id", role: "owner" };
  const manager = { id: "manager-id", role: "manager" };
  const accountant = { id: "accountant-id", role: "accountant" };

  assert.equal(identityProtectionReason(manager, owner), "لا يمكن لمدير النظام إدارة مدير نظام آخر.");
  assert.match(identityProtectionReason(manager, manager), /بنفسك/);
  assert.equal(identityProtectionReason(owner, manager), "");
  assert.equal(identityProtectionReason(manager, accountant), "");
  assert.equal(canAssignRole("manager", "owner"), false);
  assert.equal(canAssignRole("owner", "owner"), true);
});

test("owner and manager administration matrix is enforced in the UI contract", () => {
  const owner = { id: "owner-id", role: "owner" };
  const manager = { id: "manager-id", role: "manager" };
  const otherManager = { id: "manager-2", role: "manager" };
  const accountant = { id: "accountant-id", role: "accountant" };
  const production = { id: "production-id", role: "production" };

  assert.equal(canAdministerTarget(manager, otherManager), false, "manager -> manager must be denied");
  assert.equal(canAssignRole("manager", "owner"), false, "manager -> owner must be denied");
  assert.equal(canAdministerTarget(manager, accountant) && canAssignRole("manager", "accountant"), true, "manager -> accountant must be allowed");
  assert.equal(canAdministerTarget(manager, production) && canAssignRole("manager", "production"), true, "manager -> production must be allowed");
  assert.equal(canAdministerTarget(owner, otherManager) && canAssignRole("owner", "manager"), true, "owner -> manager must be allowed");
  assert.equal(identityProtectionReason(manager, otherManager), "لا يمكن لمدير النظام إدارة مدير نظام آخر.");
});

test("hierarchy hotfix protects RPC, trigger, RLS, deletion and audit", async () => {
  const sql = await readFile(hierarchyMigrationUrl, "utf8");

  assert.match(sql, /target_profile\.role in \('owner', 'manager'\)[\s\S]*target_role in \('owner', 'manager'\)/);
  assert.match(sql, /لا يمكن لمدير النظام إدارة مدير نظام آخر\./);
  assert.match(sql, /create trigger enforce_administrative_hierarchy[\s\S]*before update or delete/);
  assert.match(sql, /profiles_administration_scope[\s\S]*as restrictive[\s\S]*role in \('accountant', 'production'\)/);
  assert.match(sql, /profile_delete_attempt/);
  assert.match(sql, /source', 'administrative_hierarchy_trigger'/);
  assert.match(sql, /create or replace function public\.admin_delete_profile/);
  assert.match(sql, /grant execute on function public\.admin_delete_profile\(uuid\) to authenticated/);
});

test("production customization stays inside the safe operational boundary", () => {
  assert.deepEqual([...PRODUCTION_ALLOWED_PAGES], ["inventory", "materials", "products", "production", "assets"]);
  for (const forbidden of ["team", "auditLog", "payroll", "reports", "expenses"]) {
    assert.equal(PRODUCTION_ALLOWED_PAGES.includes(forbidden), false);
  }
});

test("owner receives the complete data set and permission loss resolves immediately", () => {
  assert.deepEqual(dataTableKeysForRole("owner"), Object.keys(TABLES));
  assert.equal(resolveAllowedTab("team", ["production"]), "production");
  assert.equal(resolveAllowedTab("team", []), null);
});

test("owner migration enforces hierarchy, last-admin safety and immutable audit", async () => {
  const sql = await readFile(migrationUrl, "utf8");

  assert.match(sql, /role in \('owner', 'manager', 'accountant', 'production'\)/);
  assert.match(sql, /when 'owner' then true[\s\S]*when 'manager' then true/);
  assert.match(sql, /Protected profile fields must be changed through admin_update_profile/);
  assert.match(sql, /actor_profile\.role = 'manager' and target_profile\.role = 'owner'/);
  assert.match(sql, /actor_profile\.role = 'manager' and target_role = 'owner'/);
  assert.match(sql, /actor_id = target_user_id/);
  assert.match(sql, /The last owner cannot be deleted/);
  assert.match(sql, /The last owner cannot be demoted/);
  assert.match(sql, /The last active owner cannot be suspended/);
  assert.match(sql, /The last active manager is required while no active owner exists/);
  assert.match(sql, /lock table public\.profiles in share row exclusive mode/);
  assert.match(sql, /not \(target_role = 'owner' and target_status = 'active'\)/);
  assert.match(sql, /page_name not in \('team', 'auditLog'\)/);
  assert.match(sql, /'\{audit_log_view\}', 'false'::jsonb/);
  assert.match(sql, /role_change_attempt/);
  assert.match(sql, /privilege_change_attempt/);
  assert.match(sql, /Audit log entries are immutable/);
  assert.match(sql, /grant execute on function public\.admin_update_profile[\s\S]*to authenticated/);
  assert.doesNotMatch(sql, /service_role[^\n]*VITE_|VITE_[A-Z_]*SERVICE/i);
});

test("new migration preserves the protected self-signup contract", async () => {
  const [currentSql, priorSql] = await Promise.all([
    readFile(migrationUrl, "utf8"),
    readFile(priorMigrationUrl, "utf8"),
  ]);

  for (const sql of [currentSql, priorSql]) {
    assert.match(sql, /new\.role not in \('accountant', 'production'\)/);
    assert.match(sql, /new\.permissions <> '\{\}'::jsonb/);
    assert.match(sql, /new\.status <> 'active'/);
  }
});

test("one-time owner script targets one existing account and keeps credentials", async () => {
  const sql = await readFile(bootstrapUrl, "utf8");

  assert.match(sql, /target_email text := null/);
  assert.match(sql, /target_user_id uuid := null/);
  assert.match(sql, /Set exactly one of target_email or target_user_id/);
  assert.match(sql, /matched_count <> 1/);
  assert.match(sql, /set role = 'owner'/);
  assert.match(sql, /credentials_changed', false/);
  assert.doesNotMatch(sql, /password\s*:=|@[a-z0-9.-]+\.[a-z]{2,}/i);
});
