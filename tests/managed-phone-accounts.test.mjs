import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const migrationUrl = new URL("../supabase/migrations/202608101700_managed_phone_accounts.sql", import.meta.url);
const edgeUrl = new URL("../supabase/functions/admin-manage-user/index.ts", import.meta.url);
const appUrl = new URL("../src/AppMonolith.jsx", import.meta.url);

test("latest identity migration disables self-registration and enforces managed hierarchy", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  assert.match(sql, /drop policy if exists profiles_insert_own/);
  assert.match(sql, /revoke insert on public\.profiles from anon, authenticated/);
  assert.match(sql, /Self-service registration is disabled/);
  assert.match(sql, /actor_role = 'manager' and new\.role in \('accountant', 'production'\)/);
  assert.match(sql, /profiles_phone_normalized_unique/);
  assert.match(sql, /must_change_password boolean not null default false/);
  assert.match(sql, /admin_register_managed_profile/);
  assert.match(sql, /temporary_password_stored', false/);
  assert.match(sql, /admin_update_managed_phone/);
  assert.match(sql, /complete_managed_password_change/);
  assert.match(sql, /auth\.role\(\) <> 'service_role'/);
  assert.match(sql, /grant execute on function public\.complete_managed_password_change\(uuid\) to service_role/);
});

test("admin Auth capability remains server-side and rolls back partial creation", async () => {
  const source = await readFile(edgeUrl, "utf8");
  assert.match(source, /caller\.auth\.getUser\(token\)/);
  assert.match(source, /admin\.auth\.admin\.createUser/);
  assert.match(source, /phone_confirm: true/);
  assert.match(source, /caller\.rpc\("admin_register_managed_profile"/);
  assert.match(source, /admin\.auth\.admin\.deleteUser\(created\.user\.id\)/);
  assert.match(source, /admin\.auth\.admin\.updateUserById/);
  assert.match(source, /body\.action === "change_password"/);
  assert.match(source, /admin\.rpc\("complete_managed_password_change"/);
  assert.doesNotMatch(source, /console\.(?:log|info)[^\n]*temporaryPassword/);
});

test("production login is phone-aware and exposes no self-signup action", async () => {
  const source = await readFile(appUrl, "utf8");
  assert.match(source, /phone: normalizeAccountPhone\(identifier\), password/);
  assert.match(source, /action: "change_password"/);
  assert.match(source, /supabase\.functions\.invoke\("admin-manage-user"/);
  assert.doesNotMatch(source, /supabase\.auth\.signUp\(/);
  assert.doesNotMatch(source, />حساب جديد</);
  assert.doesNotMatch(source, /admin_delete_profile/);
});
