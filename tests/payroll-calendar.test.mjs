import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { canApproveCalendar, dateRangeDays, localDateKey, monthCells, shiftMinutes, validateShift } from "../src/v23/calendar.js";

const migrationUrl = new URL("../supabase/migrations/202607180002_payroll_calendar_foundation.sql", import.meta.url);

test("تواريخ التقويم محلية ولا تعتمد على تحويل UTC", () => {
  assert.equal(localDateKey(new Date(2026, 6, 18, 23, 30)), "2026-07-18");
  assert.equal(dateRangeDays("2026-07-18", "2026-07-18"), 1);
  assert.equal(monthCells(2026, 6).filter(Boolean).length, 31);
});

test("الوردية الليلية تحسب اليوم التالي ولا تنتج ساعات سالبة", () => {
  assert.equal(shiftMinutes("20:00", "05:00", true), 540);
  assert.match(validateShift({ is_working_day:true, required_start_time:"20:00", required_end_time:"05:00", spans_next_day:false, break_minutes:30, required_minutes:480 }), /منتصف الليل/);
  assert.equal(validateShift({ is_working_day:true, required_start_time:"20:00", required_end_time:"05:00", spans_next_day:true, break_minutes:30, required_minutes:480 }), null);
});

test("فصل الإنشاء عن الاعتماد يطبق على المحاسب فقط", () => {
  const permissions = { payroll_calendar_approve:true };
  assert.equal(canApproveCalendar({id:"a",role:"accountant"}, "a", permissions), false);
  assert.equal(canApproveCalendar({id:"b",role:"accountant"}, "a", permissions), true);
  assert.equal(canApproveCalendar({id:"m",role:"manager"}, "m", permissions), true);
  assert.equal(canApproveCalendar({id:"o",role:"owner"}, "o", permissions), true);
  assert.equal(canApproveCalendar({id:"p",role:"production"}, "a", {payroll_calendar_approve:false}), false);
});

test("migration يحفظ التاريخ ويمنع التعارض والتعديل والحذف المباشر", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  assert.match(sql, /payroll_calendar_version_seq/);
  assert.match(sql, /valid_from_version bigint[\s\S]*valid_to_version bigint/);
  assert.match(sql, /exclude using gist \(scope_key with =, effective_period with &&\) where \(status='active'\)/);
  assert.match(sql, /exclude using gist \(scope_key with =, effective_period with &&\) where \(calendar_status='active'\)/);
  assert.match(sql, /Approved calendar revisions are immutable/);
  assert.match(sql, /Calendar records are immutable and cannot be deleted/);
  assert.match(sql, /pg_timezone_names/);
  assert.match(sql, /spans_next_day/);
  assert.match(sql, /Maker-checker approval required/);
  assert.match(sql, /Cancellation reason is required/);
  assert.match(sql, /security_invoker=true/);
  assert.match(sql, /No client write policies/);
});

test("resolver يعيد عقد التفسير الكامل as-of version", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  for (const field of ["resolved_scope","schedule_id","holiday_id","holiday_revision_id","resolution_reason","required_start_time","required_end_time","required_minutes","is_paid_holiday","is_unpaid_holiday","worked_on_holiday_eligible","overridden_events"]) assert.match(sql, new RegExp(field));
  assert.match(sql, /as_of_version bigint default null/);
  assert.match(sql, /where public\.has_permission\('payroll_calendar_view'\)/);
  assert.match(sql, /valid_from_version<=args\.v[\s\S]*valid_to_version>args\.v/);
});

test("تقادم مسودة الراتب يمنع الاعتماد دون صلاحية التجاوز", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  assert.match(sql, /calendar_stale boolean not null default false/);
  assert.match(sql, /payroll_calendar_stale_override/);
  assert.match(sql, /Payroll calendar is stale; recalculate before approval/);
  assert.match(sql, /calendar_recalculated_by=auth\.uid\(\)/);
});
