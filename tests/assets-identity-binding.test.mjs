import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { linkedProfileForEmployee } from "../src/assets/domain.js";

const migration = await readFile(new URL("../supabase/migrations/202607180007_bind_asset_employee_profile_identity.sql", import.meta.url), "utf8");
const page = await readFile(new URL("../src/assets/AssetsPage.jsx", import.meta.url), "utf8");
const app = await readFile(new URL("../src/AppMonolith.jsx", import.meta.url), "utf8");

test("Employee A cannot resolve Profile B as its linked account", () => {
  const profiles = [{ id:"profile-b",employee_id:"employee-b",status:"active" }];
  assert.equal(linkedProfileForEmployee(profiles,"employee-a"),null);
});

test("a canonical active employee/profile pair resolves for issue", () => {
  const profile = { id:"profile-a",employee_id:"employee-a",status:"active" };
  assert.equal(linkedProfileForEmployee([profile],"employee-a"),profile);
  assert.match(migration,/linked\.employee_id is distinct from emp\.id/);
});

test("unlinked employees remain bearer-link only", () => {
  assert.equal(linkedProfileForEmployee([],"employee-a"),null);
  assert.match(page,/لا يوجد حساب نظام مرتبط — التأكيد عبر الرابط غير موثّق بالهوية/);
  assert.match(migration,/supplied_profile_id is null then 'bearer_link'/);
  assert.match(migration,/receiver_profile_id is not null then return jsonb_build_object\('status','authentication_required'\)/);
});

test("authenticated assignment confirmation binds auth profile to the selected employee", () => {
  const body = migration.match(/create or replace function public\.confirm_asset_assignment_authenticated[\s\S]*?end \$\$;/)?.[0] || "";
  assert.match(body,/assignment\.receiver_profile_id<>actor/);
  assert.match(body,/linked\.employee_id is distinct from assignment\.receiver_employee_id/);
  assert.match(body,/linked\.status<>'active'/);
});

test("authenticated return confirmation applies the same employee binding", () => {
  const body = migration.match(/create or replace function public\.confirm_asset_return_authenticated[\s\S]*?end \$\$;/)?.[0] || "";
  assert.match(body,/assignment\.receiver_profile_id<>actor/);
  assert.match(body,/linked\.employee_id is distinct from assignment\.receiver_employee_id/);
  assert.match(body,/linked\.status<>'active'/);
});

test("inactive profiles never resolve and cannot confirm", () => {
  assert.equal(linkedProfileForEmployee([{id:"p",employee_id:"e",status:"suspended"}],"e"),null);
  assert.match(migration,/linked\.status<>'active'/);
  assert.match(migration,/profile\.status='active'/);
});

test("direct writes and RPC calls cannot bypass canonical identity binding", () => {
  assert.match(migration,/create trigger validate_asset_assignment_identity_binding/);
  assert.match(migration,/before insert or update of receiver_employee_id,receiver_profile_id/);
  assert.match(migration,/Employee identity links must be changed through admin_link_profile_employee/);
  assert.match(migration,/Owner authorization required/);
  assert.match(migration,/lock table public\.profiles in share row exclusive mode/);
});

test("UI removes arbitrary profile selection and Team provides audited Owner linking", () => {
  assert.doesNotMatch(page,/data\.profiles\.filter\(p=>p\.status==="active"\)\.map\(p=><option/);
  assert.match(page,/linkedProfileForEmployee\(data\.profiles,employeeId\)/);
  assert.match(app,/admin_link_profile_employee/);
  assert.match(app,/currentProfile\.role === "owner"/);
  assert.match(app,/سبب الربط أو التغيير/);
  assert.match(migration,/asset_identity_binding_migration_report/);
  assert.match(migration,/invalid_identity_link_neutralized/);
});
