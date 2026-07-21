import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const ui = fs.readFileSync("src/v22/dailyLabor.jsx", "utf8");
const migration = fs.readFileSync("supabase/migrations/20260721161000_external_labor_review_workflow.sql", "utf8");
const fix = fs.readFileSync("supabase/migrations/20260721164000_external_labor_payment_parameter_fix.sql", "utf8");

test("external labor requires opening details before approval or payment", () => {
  assert.match(ui, /فتح التفاصيل/);
  assert.match(ui, /تفاصيل وردية العمالة الخارجية/);
  assert.match(ui, /review_daily_labor/);
  assert.match(ui, /pay_daily_labor/);
  assert.doesNotMatch(ui, /from\("daily_labor"\)\.update\(\{payment_status:"paid"/);
});

test("shift detail explains time and amount calculation", () => {
  for (const label of ["بداية الوردية", "نهاية الوردية", "الراحة", "الساعات الفعلية", "الساعات الإضافية", "سعر الساعة", "سعر الإضافي", "الإجمالي المحتسب"]) {
    assert.match(ui, new RegExp(label));
  }
  assert.match(ui, /طريقة الحساب/);
});

test("review and payment are protected by database workflow", () => {
  assert.match(migration, /review_status in \('draft','rejected','approved'\)/);
  assert.match(migration, /Rejection reason is required/);
  assert.match(migration, /must be approved before payment/);
  assert.match(migration, /Reviewed, paid, or posted daily labor cannot be deleted/);
  assert.match(migration, /revoke all on function public\.review_daily_labor.*public, anon/);
  assert.match(migration, /revoke all on function public\.pay_daily_labor.*public, anon/);
});

test("payment parameter ambiguity is fixed without destructive changes", () => {
  assert.match(fix, /payment_reference=nullif\(btrim\(\$2\), ''\)/);
  assert.match(fix, /payment_notes=nullif\(btrim\(\$3\), ''\)/);
  assert.doesNotMatch(fix, /drop table|truncate|delete from public\.daily_labor/i);
});

test("delete action is only shown for untouched draft shifts", () => {
  assert.match(ui, /review_status \|\| "draft"\) === "draft"/);
  assert.match(ui, /row\.payment_status !== "paid"/);
  assert.match(ui, /!row\.actual_cost_entry_id/);
});
