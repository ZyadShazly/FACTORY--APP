import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const cleanup = fs.readFileSync(
  "supabase/migrations/202607220001_pilot_security_permission_cleanup.sql",
  "utf8",
);
const publicGrantCleanup = fs.readFileSync(
  "supabase/migrations/202607220002_pilot_security_public_grant_cleanup.sql",
  "utf8",
);

const publicAssetEndpoints = [
  "asset_confirmation_preview",
  "asset_return_confirmation_preview",
  "confirm_asset_assignment",
  "confirm_asset_return",
];

test("pilot permission cleanup preserves only token-based public asset endpoints", () => {
  for (const endpoint of publicAssetEndpoints) {
    assert.match(cleanup, new RegExp(`'${endpoint}'`));
    assert.match(publicGrantCleanup, new RegExp(`'${endpoint}'`));
  }
  assert.match(publicGrantCleanup, /p\.prosecdef/);
  assert.match(publicGrantCleanup, /revoke execute on function %s from public, anon/i);
});

test("trigger functions are not callable as application RPCs", () => {
  for (const migration of [cleanup, publicGrantCleanup]) {
    assert.match(migration, /pg_catalog\.trigger/);
    assert.match(
      migration,
      /revoke execute on function %s from public, anon, authenticated/i,
    );
  }
});

test("mutable search paths found by the live advisor are fixed", () => {
  for (const signature of [
    "public.set_updated_at()",
    "public.calculate_daily_labor()",
    "public.normalize_department_name(text)",
    "public.calendar_shift_minutes(time without time zone, time without time zone, boolean)",
  ]) {
    assert.ok(cleanup.includes(`alter function ${signature} set search_path = public, pg_temp;`));
  }
});
