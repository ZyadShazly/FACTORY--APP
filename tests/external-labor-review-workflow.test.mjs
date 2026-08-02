import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const ui = fs.readFileSync("src/v22/dailyLabor.jsx", "utf8");
const migration = fs.readFileSync("supabase/migrations/202607210003_external_labor_review_workflow.sql", "utf8");
const fix = fs.readFileSync("supabase/migrations/20260721164000_external_labor_payment_parameter_fix.sql", "utf8");
const settlement = fs.readFileSync("supabase/migrations/202608020004_external_labor_settlement.sql", "utf8");

test("external labor requires opening details before approval or payment", () => {
  assert.match(ui, /فتح التفاصيل/);
  assert.match(ui, /تفاصيل وردية العمالة الخارجية/);
  assert.match(ui, /review_daily_labor/);
  assert.match(ui, /pay_daily_labor/);
  assert.doesNotMatch(ui, /from\("daily_labor"\)\.update\(\{payment_status:"paid"/);
});

test("external labor settlement shows additions deductions reasons and net", () => {
  for (const label of ["إضافات", "سبب الإضافة", "خصومات", "سبب الخصم", "صافي التسوية"]) {
    assert.match(ui, new RegExp(label));
  }
  assert.match(settlement, /net_amount numeric generated always as/);
  assert.match(settlement, /paid_amount=net_amount/);
  assert.match(settlement, /deduction_amount <= total_amount \+ addition_amount/);
  assert.match(ui, /الخصم لا يمكن أن يتجاوز الإجمالي بعد الإضافات/);
});

test("reviewed settlement values are immutable and active access is restrictive", () => {
  assert.match(settlement, /Reviewed daily labor settlement is immutable/);
  assert.match(settlement, /before update on public\.daily_labor/);
  assert.match(settlement, /as restrictive[\s\S]*for all to authenticated/);
  assert.match(settlement, /revoke all on function public\.pay_daily_labor\(uuid,text,text\)[\s\S]*public,anon,authenticated/);
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
