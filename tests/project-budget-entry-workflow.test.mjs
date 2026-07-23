import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const source = fs.readFileSync("src/v22/projectBudget.jsx", "utf8");

test("budget draft exposes a clear first-step workflow", () => {
  assert.match(source, /تجهيز الأقسام وكتابة أول بند/);
  assert.match(source, /DEFAULT_SECTIONS/);
  assert.match(source, /save_project_budget_section/);
  assert.match(source, /إضافة بند/);
});

test("empty budgets cannot be submitted for approval", () => {
  assert.match(source, /if\(!sections\.length\|\|!items\.length\)/);
  assert.match(source, /disabled=\{busy\|\|!canSubmit\}/);
  assert.match(source, /أضف بند ميزانية واحدًا على الأقل قبل الإرسال/);
});

test("activation readiness explains the missing manager and next step", () => {
  assert.match(source, /مدير المشروع يُحدد من تبويب «الفريق»/);
  assert.match(source, /ارجع إلى «نظرة عامة» لتفعيل المشروع/);
});
