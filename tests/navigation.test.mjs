import test from "node:test";
import assert from "node:assert/strict";
import { buildNavigationGroups, loadNavigationState, NAV_GROUPS } from "../src/navigation.js";

test("هيكل التنقل يغطي كل صفحة مرة واحدة", () => {
  const pageIds = NAV_GROUPS.flatMap((group) => group.pages);
  assert.equal(new Set(pageIds).size, pageIds.length);
  assert.equal(pageIds.length, 20);
});

test("التنقل لا يعرض إلا الصفحات المسموحة", () => {
  const items = [
    { id: "dashboard", label: "الرئيسية" },
    { id: "projects", label: "المشاريع" },
    { id: "payroll", label: "الرواتب" },
    { id: "team", label: "الإدارة" },
  ];
  const groups = buildNavigationGroups(items, ["projects", "payroll"]);
  assert.deepEqual(groups.flatMap((group) => group.items.map((item) => item.id)), ["projects", "payroll"]);
  assert.deepEqual(groups.map((group) => group.id), ["projects", "hr"]);
});

test("حالة فتح المجموعات تستعاد بأمان", () => {
  const storage = { getItem: () => JSON.stringify({ finance: false }) };
  const state = loadNavigationState(storage);
  assert.equal(state.finance, false);
  assert.equal(state.home, true);
  assert.equal(state.projects, false);
});

test("العملاء والإيجارات ضمن دورة الإيراد والإعدادات ضمن الإدارة", () => {
  const finance = NAV_GROUPS.find((group) => group.id === "finance");
  const admin = NAV_GROUPS.find((group) => group.id === "admin");
  assert.ok(finance.pages.includes("customers"));
  assert.ok(finance.pages.includes("rentals"));
  assert.ok(admin.pages.includes("settings"));
});
