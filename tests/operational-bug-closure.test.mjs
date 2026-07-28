import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

function source(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function copyFixture(root, relativePath, lineEnding) {
  const target = path.join(root, relativePath);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const content = fs.readFileSync(relativePath, "utf8").replace(/\r\n|\r|\n/g, lineEnding);
  fs.writeFileSync(target, content);
}

function fixtureSnapshot(root, relativePaths) {
  return Object.fromEntries(
    relativePaths.map((relativePath) => [
      relativePath,
      fs.readFileSync(path.join(root, relativePath), "utf8"),
    ])
  );
}

test("operational patch is idempotent across LF and CRLF checkouts", () => {
  const fixtureFiles = [
    "scripts/apply-operational-bug-closure.mjs",
    "src/AppMonolith.jsx",
    "src/auth/useProfileBootstrap.js",
    "src/assets/AssetsPage.jsx",
    "src/v22/payroll.jsx",
  ];

  for (const [checkout, lineEnding] of [["LF", "\n"], ["CRLF", "\r\n"]]) {
    const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "factory-operational-patch-"));
    try {
      for (const filePath of fixtureFiles) copyFixture(fixtureRoot, filePath, lineEnding);

      const runPatch = () => spawnSync(
        process.execPath,
        ["scripts/apply-operational-bug-closure.mjs"],
        { cwd: fixtureRoot, encoding: "utf8" }
      );
      const before = fixtureSnapshot(fixtureRoot, fixtureFiles);

      const first = runPatch();
      assert.equal(first.status, 0, `${checkout}: ${first.stderr || first.stdout}`);
      assert.deepEqual(fixtureSnapshot(fixtureRoot, fixtureFiles), before, `${checkout}: first rerun changed patched sources`);

      const second = runPatch();
      assert.equal(second.status, 0, `${checkout}: ${second.stderr || second.stdout}`);
      assert.deepEqual(fixtureSnapshot(fixtureRoot, fixtureFiles), before, `${checkout}: second rerun changed patched sources`);
    } finally {
      fs.rmSync(fixtureRoot, { recursive: true, force: true });
    }
  }
});

test("authentication failures are localized and network errors are caught", () => {
  const app = source("src/AppMonolith.jsx");
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
  assert.match(assets, /result\.receiver_phone\|\|phone/);
  assert.match(assets, /whatsappUrl\(share\.phone,share\.message\)/);
});

test("employee lifecycle is checked and finalized payroll stays immutable", () => {
  const payroll = source("src/v22/payroll.jsx");
  assert.doesNotMatch(payroll, /from\("employees"\)\.delete\(\)/);
  assert.match(payroll, /supabase\.rpc\("set_employee_status"/);
  assert.match(payroll, /supabase\.rpc\("delete_employee_if_unused"/);
  assert.match(payroll, /row\.status !== "draft"/);
  assert.match(payroll, /p\.status === "draft"/);
});

test("database migration provides defense in depth", () => {
  const migration = source("supabase/migrations/202607200001_operational_bug_closure.sql");
  const employeeWorkflow = source("supabase/migrations/20260721100000_employee_management_workflow.sql");
  const deleteGuard = source("supabase/migrations/20260721101000_employee_delete_guard_reconcile.sql");
  assert.match(migration, /create or replace function public\.complete_my_profile\(\)/i);
  assert.match(migration, /grant execute on function public\.complete_my_profile\(\) to authenticated/i);
  assert.match(migration, /prevent_employee_delete_trigger/i);
  assert.match(migration, /prevent_finalized_payroll_delete_trigger/i);
  assert.match(migration, /old\.status <> 'draft'/i);
  assert.match(employeeWorkflow, /delete_employee_if_unused/i);
  assert.match(deleteGuard, /Employees cannot be deleted directly/i);
});
