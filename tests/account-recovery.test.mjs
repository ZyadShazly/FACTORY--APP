import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { bootstrapErrorMessage, withTimeout } from "../src/bootstrap.js";

const migrationUrl = new URL("../supabase/migrations/202607180001_account_bootstrap_recovery.sql", import.meta.url);

test("bootstrap timeout rejects with a user-facing recovery error", async () => {
  await assert.rejects(withTimeout(new Promise(() => {}), 5, "انتهت المهلة"), (error) => error.code === "NEXTEP_TIMEOUT" && error.message === "انتهت المهلة");
  assert.equal(bootstrapErrorMessage({ code: "NEXTEP_TIMEOUT", message: "انتهت المهلة" }, "فشل"), "انتهت المهلة");
});

test("account recovery RPC is least privilege, audited and keeps triggers enabled", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  assert.match(sql, /admin_repair_missing_profile/);
  assert.match(sql, /actor_role not in \('owner', 'manager'\)/);
  assert.match(sql, /target_role not in \('accountant', 'production'\)/);
  assert.match(sql, /from auth\.users where id = target_user_id/);
  assert.match(sql, /if exists \(select 1 from public\.profiles/);
  assert.match(sql, /permissions, status[\s\S]*'\{\}'::jsonb,[\s\S]*'active'/);
  assert.match(sql, /account_profile_repaired/);
  assert.match(sql, /credentials_changed', false/);
  assert.match(sql, /page_name <> 'settings'/);
  assert.match(sql, /grant execute on function public\.admin_repair_missing_profile[\s\S]*to authenticated/);
  assert.doesNotMatch(sql, /disable trigger|service_role[\s\S]*VITE_/i);
});

test("missing profile is an explicit recoverable bootstrap state", async () => {
  const [hook, screen] = await Promise.all([
    readFile(new URL("../src/auth/useProfileBootstrap.js", import.meta.url), "utf8"),
    readFile(new URL("../src/auth/BootstrapScreens.jsx", import.meta.url), "utf8"),
  ]);
  assert.match(hook, /setStatus\("missing-profile"\)/);
  assert.match(hook, /withTimeout\([\s\S]*profiles/);
  assert.match(screen, /فشل إعداد الحساب/);
  assert.match(screen, /إعادة المحاولة/);
  assert.match(screen, /تسجيل الخروج/);
});
