import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { spawnSync } from "node:child_process";

function source(path) {
  return fs.readFileSync(path, "utf8");
}

test("operational patch is idempotent", () => {
  const first = spawnSync(process.execPath, ["scripts/apply-operational-bug-closure.mjs"], { encoding: "utf8" });
  assert.equal(first.status, 0, first.stderr || first.stdout);
  const second = spawnSync(process.execPath, ["scripts/apply-operational-bug-closure.mjs"], { encoding: "utf8" });
  assert.equal(second.status, 0, second.stderr || second.stdout);
});

test("authentication failures are localized and network errors are caught", () => {
  const app = source("src/App.jsx");
  assert.match(app, /function authErrorMessage\(error\)/);
  assert.match(app, /تعذر الاتصال بالخادم/);
  assert.match(app, /catch \(error\) \{\s*setErr\(authErrorMessage\(error\)\)/);
  assert.match(app, /options: \{ data: \{ full_name: fullName\.trim\(\), role \} \}/);
  assert.match(app, /supabase\.rpc\("complete_my_profile"\)/);
});

test("missing profiles self-recover after confirmed login", () => {
  const bootstrap = source("src/auth/useProfileBootstrap.js");
  assert.match(bootstrap, /let fetchResult = await withTimeout/);
  assert.match(bootstrap, /supabase\.rpc\("complete_my_profile"\)/);
  assert.match(bootstrap, /تعذر استكمال ملف الحساب/);
});

test("asset assignment supports partial return continuation and stable sharing phone", () => {
  const assets = source("src/assets/AssetsPage.jsx");
  assert.match(assets, /\["issued","partially_returned"\]\.includes\(a\.status\)/);
  assert.match(assets, /selectedEmployee\?\.phone\|\|ass\?\.receiver_phone_snapshot/);
});

test("employees are suspended instead of deleted and finalized payroll stays immutable", () => {
  const payroll = source("src/v22/payroll.jsx");
  assert.doesNotMatch(payroll, /from\("employees"\)\.delete\(\)/);
  assert.match(payroll, /update\(\{status:"suspended"\}\)/);
  assert.match(payroll, /row\.status!=="draft"/);
  assert.match(payroll, /p\.status==="draft"/);
});

test("database migration provides defense in depth", () => {
  const migration = source("supabase/migrations/202607200001_operational_bug_closure.sql");
  assert.match(migration, /create or replace function public\.complete_my_profile\(\)/i);
  assert.match(migration, /grant execute on function public\.complete_my_profile\(\) to authenticated/i);
  assert.match(migration, /prevent_employee_delete_trigger/i);
  assert.match(migration, /prevent_finalized_payroll_delete_trigger/i);
  assert.match(migration, /old\.status <> 'draft'/i);
});
