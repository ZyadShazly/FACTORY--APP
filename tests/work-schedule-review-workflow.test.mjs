import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const ui = fs.readFileSync("src/v23/workCalendar.jsx", "utf8");
const migration = fs.readFileSync("supabase/migrations/202607212220_work_schedule_review_and_cancellation.sql", "utf8");

test("schedule approval is only available from the review dialog", () => {
  assert.match(ui, /فتح التفاصيل/);
  assert.match(ui, /مراجعة جدول العمل قبل القرار/);
  assert.match(ui, /اعتماد بعد المراجعة/);
  assert.doesNotMatch(ui, /onClick=\{\(\)=>approveSchedule\(s\)\}/);
});

test("schedule review shows payroll and employee impact", () => {
  assert.match(ui, /الموظفون المتأثرون/);
  assert.match(ui, /مسودات رواتب تحتاج إعادة حساب/);
  assert.match(ui, /رواتب معتمدة\/مدفوعة تاريخيًا/);
});

test("database workflow requires reasons and protects future cancellation", () => {
  assert.match(migration, /Rejection reason is required/);
  assert.match(migration, /Cancellation reason is required/);
  assert.match(migration, /Future cancellation requires a replacement schedule first/);
  assert.match(migration, /revoke all on function public\.cancel_work_schedule\(uuid,date,text\) from public, anon/);
});
