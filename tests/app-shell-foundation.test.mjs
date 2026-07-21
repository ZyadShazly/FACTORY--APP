import test from "node:test";
import assert from "node:assert/strict";

import { ALL_PAGE_IDS, NAV_BY_ROLE, PAGE_DESCRIPTIONS, PAGE_LABELS, pageLabel } from "../src/app/pageMetadata.js";
import { authErrorMessage } from "../src/auth/authErrorMessage.js";

test("page metadata keeps required pilot boundaries", () => {
  for (const page of ["projects", "inventory", "purchases", "production", "assets", "employees", "workCalendar", "payroll", "dailyLabor", "reports", "settings"]) {
    assert.ok(ALL_PAGE_IDS.includes(page), `${page} must stay registered`);
    assert.ok(PAGE_LABELS[page], `${page} must have a label`);
    assert.ok(PAGE_DESCRIPTIONS[page], `${page} must have a description`);
  }
  assert.equal(new Set(ALL_PAGE_IDS).size, ALL_PAGE_IDS.length, "page ids must be unique");
  assert.ok(NAV_BY_ROLE.production.includes("production"));
  assert.ok(!NAV_BY_ROLE.production.includes("payroll"));
  assert.equal(pageLabel("unknownPage"), "unknownPage");
});

test("authentication errors remain safe and user-facing", () => {
  assert.match(authErrorMessage({ message: "Invalid login credentials" }), /بيانات الدخول/);
  assert.match(authErrorMessage({ message: "Email not confirmed" }), /أكد الإيميل/);
  assert.match(authErrorMessage({ message: "Failed to fetch" }), /الاتصال بالخادم/);
  assert.equal(authErrorMessage({ message: "Custom server message" }), "Custom server message");
  assert.match(authErrorMessage(null), /تعذر إتمام العملية/);
});
