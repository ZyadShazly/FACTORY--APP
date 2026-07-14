import test from "node:test";
import assert from "node:assert/strict";
import { calculateDailyLabor, calculateNetSalary } from "../src/v22/calculations.js";
import { buildProjectFilePath, PROJECT_FILES_BUCKET, PROJECT_FILES_TABLE } from "../src/v22/fileTypes.js";
import { syncMutation } from "../src/v22/mutations.js";

test("حساب صافي الراتب يشمل البدلات والإضافي والخصومات والسلف", () => {
  assert.equal(calculateNetSalary({ base_salary: 5000, housing_allowance: 1000, transport_allowance: 500, other_allowance: 250, overtime_hours: 10, overtime_rate: 50, bonuses: 300, deductions: 200, advances: 400 }), 6950);
});

test("وردية 12:00 إلى 20:00 تساوي 8 ساعات و200", () => {
  assert.deepEqual(calculateDailyLabor({ start_time: "12:00", end_time: "20:00", break_minutes: 0, hourly_rate: 25 }), { totalHours: 8, normalHours: 8, overtimeAmount: 0, totalAmount: 200 });
});

test("يدعم الوردية التي تتجاوز منتصف الليل", () => {
  assert.deepEqual(calculateDailyLabor({ start_time: "22:00", end_time: "06:00", break_minutes: 60, hourly_rate: 20, overtime_hours: 2, overtime_rate: 30 }), { totalHours: 7, normalHours: 5, overtimeAmount: 60, totalAmount: 160 });
});

test("مسار ملف المشروع يستخدم نفس معرف المشروع ويُنظف اسم الملف", () => {
  assert.equal(buildProjectFilePath("project-123", "مخطط نهائي.pdf", "file-1"), "project-123/file-1-----------.pdf");
  assert.equal(PROJECT_FILES_BUCKET, "project-files");
  assert.equal(PROJECT_FILES_TABLE, "project_files");
  assert.throws(() => buildProjectFilePath(null, "file.pdf", "file-1"), /projectId is required/);
});

test("mutation الناجحة تنتظر refetch وتعيد الحالة الجديدة", async () => {
  let refetched = false;
  const result = await syncMutation({
    scope: "test:create",
    mutationResult: { data: { id: "new-row" }, error: null },
    refetch: async () => { refetched = true; return { data: [{ id: "new-row" }], error: null }; },
  });
  assert.equal(refetched, true);
  assert.equal(result.error, null);
  assert.deepEqual(result.refetchResult.data, [{ id: "new-row" }]);
});

test("mutation الفاشلة لا تنفذ refetch", async () => {
  let refetched = false;
  const mutationError = new Error("mutation failed");
  const result = await syncMutation({
    scope: "test:failed",
    mutationResult: { data: null, error: mutationError },
    refetch: async () => { refetched = true; return { data: [], error: null }; },
  });
  assert.equal(refetched, false);
  assert.equal(result.error, mutationError);
});
