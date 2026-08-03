import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const ui = fs.readFileSync("src/v22/dailyLabor.jsx", "utf8");
const migration = fs.readFileSync("supabase/migrations/202607210003_external_labor_review_workflow.sql", "utf8");
const fix = fs.readFileSync("supabase/migrations/20260721164000_external_labor_payment_parameter_fix.sql", "utf8");
const settlement = fs.readFileSync("supabase/migrations/202608020004_external_labor_settlement.sql", "utf8");
const correction = fs.readFileSync("supabase/migrations/20260803052525_daily_labor_correction_archive.sql", "utf8");
const correctionIndexes = fs.readFileSync("supabase/migrations/20260803053906_daily_labor_correction_indexes.sql", "utf8");

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
  assert.match(ui, /number\(row\.correction_count\) === 0/);
});

test("rejected shifts use an audited correction workflow before another review", () => {
  assert.match(ui, /correct_daily_labor/);
  assert.match(ui, /تصحيح الوردية/);
  assert.match(ui, /سبب التصحيح/);
  assert.match(correction, /create table if not exists public\.daily_labor_corrections/);
  assert.match(correction, /before_snapshot jsonb not null/);
  assert.match(correction, /after_snapshot jsonb not null/);
  assert.match(correction, /Only rejected daily labor shifts can be corrected/);
  assert.match(correction, /review_status='draft',reviewed_by=null,reviewed_at=null,rejection_reason=null/);
  assert.match(correction, /Rejected daily labor shift must be corrected before review/);
  assert.doesNotMatch(correction, /on delete cascade/i);
});

test("review payment and correction audit fields cannot bypass protected RPCs", () => {
  assert.match(correction, /Daily labor review fields can only change through review workflow/);
  assert.match(correction, /Daily labor payment fields can only change through payment workflow/);
  assert.match(correction, /Daily labor correction audit fields are immutable/);
  for (const signature of [
    "review_daily_labor\\(uuid,boolean,text\\)",
    "pay_daily_labor\\(uuid,text,text\\)",
    "correct_daily_labor\\(uuid,text,jsonb\\)",
    "get_daily_labor_corrections\\(uuid\\)",
  ]) assert.match(correction, new RegExp(`revoke all on function public\\.${signature}[\\s\\S]*public,anon,authenticated`));
});

test("payment calculation preserves additions in the paid net amount", () => {
  assert.match(correction, /settlement_cap := greatest\(new\.total_amount \+ coalesce\(new\.addition_amount,0\) - coalesce\(new\.deduction_amount,0\),0\)/);
  assert.match(correction, /new\.paid_amount := least\(greatest\(new\.paid_amount,0\),settlement_cap\)/);
  assert.match(correction, /paid_amount=net_amount/);
});

test("active work is separated from collapsed immutable history", () => {
  assert.match(ui, /const activeRows = useMemo/);
  assert.match(ui, /const archivedRows = useMemo/);
  assert.match(ui, /ArchiveSection title="سجل الورديات المكتملة والمرفوضة"/);
  assert.match(ui, /الورديات المدفوعة أو المرفوضة أو المرحلة للتكلفة محفوظة هنا/);
  assert.match(ui, /get_daily_labor_corrections/);
  assert.match(ui, /سجل التصحيحات/);
});

test("daily labor correction actor foreign keys are covered", () => {
  assert.match(correctionIndexes, /daily_labor_last_corrected_by_idx[\s\S]*daily_labor\(last_corrected_by\)/);
  assert.match(correctionIndexes, /daily_labor_corrections_corrected_by_idx[\s\S]*daily_labor_corrections\(corrected_by\)/);
  assert.doesNotMatch(correctionIndexes, /drop table|truncate|delete from/i);
});
