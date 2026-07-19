import test from "node:test";
import assert from "node:assert/strict";
import { calculateDailyLabor, calculateNetSalary } from "../src/v22/calculations.js";
import { buildProjectFilePath, PROJECT_FILES_BUCKET, PROJECT_FILES_TABLE } from "../src/v22/fileTypes.js";
import { syncMutation } from "../src/v22/mutations.js";
import { auditActorLabel } from "../src/v22/auditIdentity.js";
import { combinedRealtimeStatus, dataTableKeysForRole, isActiveProfile, REALTIME_TABLE_TO_KEY, resolveAllowedTab } from "../src/realtime.js";

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

test("هوية سجل التدقيق تعرض الاسم ثم البريد ثم النظام ثم UUID", () => {
  assert.equal(auditActorLabel({ actor: { full_name: "زياد شاذلي", email: "z@example.com" }, actor_id: "user-id" }), "زياد شاذلي");
  assert.equal(auditActorLabel({ actor: { full_name: "", email: "z@example.com" }, actor_id: "user-id" }), "z@example.com");
  assert.equal(auditActorLabel({ actor_id: null }), "النظام");
  assert.equal(auditActorLabel({ actor_id: "6775d4cb-0000-4000-8000-000000000000" }), "6775d4cb-0000-4000-8000-000000000000");
});

test("خريطة Realtime تغطي الجداول التشغيلية الموجودة في state", () => {
  const tables = Object.keys(REALTIME_TABLE_TO_KEY);
  for (const table of ["profiles", "projects", "project_files", "payroll", "daily_labor", "materials", "material_purchases", "production_orders", "expenses", "audit_log"]) {
    assert.equal(tables.includes(table), true, `${table} must be subscribed`);
  }
  assert.equal(new Set(Object.values(REALTIME_TABLE_TO_KEY)).size, tables.length);
});

test("تغيير الصلاحيات ينقل المستخدم من الصفحة الممنوعة", () => {
  assert.equal(resolveAllowedTab("payroll", ["projects", "inventory"]), "projects");
  assert.equal(resolveAllowedTab("inventory", ["projects", "inventory"]), "inventory");
  assert.equal(resolveAllowedTab("payroll", []), null);
});

test("حالة الحساب والاتصال اللحظي تُحسب بأمان", () => {
  assert.equal(isActiveProfile({ status: "active" }), true);
  assert.equal(isActiveProfile({}), true);
  assert.equal(isActiveProfile({ status: "suspended" }), false);
  assert.equal(combinedRealtimeStatus({ data: "SUBSCRIBED", profile: "SUBSCRIBED" }), "CONNECTED");
  assert.equal(combinedRealtimeStatus({ data: "CHANNEL_ERROR", profile: "SUBSCRIBED" }), "RECONNECTING");
});

test("موظف الإنتاج لا يحمّل الجداول المالية أو الإدارية", () => {
  assert.deepEqual(dataTableKeysForRole("production"), ["projects", "projectFiles", "projectActivities", "projectMilestones", "projectMembers", "materials", "products", "productionOrders"]);
  assert.equal(dataTableKeysForRole("production").includes("materialPurchases"), false);
  assert.equal(dataTableKeysForRole("production").includes("dailyLabor"), false);
  assert.equal(dataTableKeysForRole("production", true).includes("assets"), true);
  assert.equal(dataTableKeysForRole("production", true).includes("assetSettlements"), false);
  assert.equal(dataTableKeysForRole("manager").includes("payroll"), true);
  assert.equal(dataTableKeysForRole("accountant").includes("expenses"), true);
});
