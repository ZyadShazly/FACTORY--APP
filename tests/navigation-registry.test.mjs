import assert from "node:assert/strict";
import test from "node:test";

import {
  APP_TAB_IDS,
  APP_TAB_LABELS,
  APP_TABS,
  findTab,
  visibleTabs,
} from "../src/app/navigationRegistry.js";

test("navigation registry keeps unique stable tab ids", () => {
  assert.equal(new Set(APP_TAB_IDS).size, APP_TAB_IDS.length);
  assert.deepEqual(
    APP_TAB_IDS,
    APP_TABS.map((tab) => tab.id),
  );
});

test("every registered tab has a label and icon", () => {
  for (const tab of APP_TABS) {
    assert.equal(typeof tab.id, "string");
    assert.ok(tab.id.length > 0);
    assert.equal(typeof tab.label, "string");
    assert.ok(tab.label.length > 0);
    assert.equal(typeof tab.icon, "object");
    assert.equal(APP_TAB_LABELS[tab.id], tab.label);
  }
});

test("visibleTabs preserves registry order and filters permissions", () => {
  const result = visibleTabs(["payroll", "projects", "dashboard"]);
  assert.deepEqual(result.map((tab) => tab.id), ["dashboard", "projects", "payroll"]);
});

test("findTab resolves known tabs and rejects unknown ids", () => {
  assert.equal(findTab("production")?.label, "أوامر الإنتاج");
  assert.equal(findTab("missing"), null);
});
