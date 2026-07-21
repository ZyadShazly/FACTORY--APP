import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const ui=fs.readFileSync("src/v22/PayrollReviewTab.jsx","utf8");
const migration=fs.readFileSync("supabase/migrations/20260721102000_payroll_review_workflow.sql","utf8");
const app=fs.readFileSync("src/App.jsx","utf8");

test("payroll list requires opening details before approval",()=>{
  assert.match(ui,/فتح التفاصيل/);
  assert.match(ui,/اعتماد بعد المراجعة/);
  assert.doesNotMatch(ui,/onClick=\{\(\)=>setWorkflow\(p,"approved"\)\}/);
});

test("payroll details explain every financial component",()=>{
  for(const label of ["الراتب الأساسي","بدل السكن","بدل النقل","الإضافي","سبب الخصم","تفاصيل السلفة","سبب المكافأة","صافي المطلوب دفعه"]){
    assert.match(ui,new RegExp(label));
  }
  assert.match(ui,/لا يوجد حاليًا سجل حضور تفصيلي/);
});

test("rejection and recalculation use protected database functions",()=>{
  assert.match(ui,/update_payroll_review/);
  assert.match(ui,/review_payroll/);
  assert.match(migration,/Only draft or rejected payroll can be recalculated/);
  assert.match(migration,/Rejection reason is required/);
});

test("approval requires reasons for deductions advances and bonuses",()=>{
  assert.match(migration,/Deduction reason is required before approval/);
  assert.match(migration,/Advance reason is required before approval/);
  assert.match(migration,/Bonus reason is required before approval/);
});

test("application routes payroll page to the review screen",()=>{
  assert.match(app,/PayrollReviewTab as PayrollTab/);
});
