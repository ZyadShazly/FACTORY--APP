import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const migrationUrl = new URL("../supabase/migrations/202607210005_pilot_uat_alerts_calendar.sql", import.meta.url);
const appUrl = new URL("../src/AppMonolith.jsx", import.meta.url);
const calendarUrl = new URL("../src/v23/workCalendar.jsx", import.meta.url);

test("asset alerts are loaded through a permission-aware RPC", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  const app = await readFile(appUrl, "utf8");
  assert.match(sql, /create or replace function public\.get_asset_alerts_visible\(\)/i);
  assert.match(sql, /security definer/i);
  assert.match(sql, /set search_path=public,pg_temp/i);
  assert.match(sql, /has_permission\('assets_view'\)/i);
  assert.match(sql, /revoke all on function public\.get_asset_alerts_visible\(\) from public,anon/i);
  assert.match(app, /key === "assetAlerts"[\s\S]*get_asset_alerts_visible/);
});

test("calendar warns when there is no active schedule and opens the review workflow", async () => {
  const calendar = await readFile(calendarUrl, "utf8");
  assert.match(calendar, /draftSchedules/);
  assert.match(calendar, /activeSchedules/);
  assert.match(calendar, /لا يوجد جدول عمل مفعّل حاليًا/);
  assert.match(calendar, /فتح جداول العمل/);
  assert.match(calendar, /مراجعة جدول العمل قبل القرار/);
  assert.match(calendar, /setView\("schedules"\)/);
});
