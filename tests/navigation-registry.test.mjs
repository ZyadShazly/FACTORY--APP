import assert from "node:assert/strict";
import test from "node:test";

import {
  APP_PAGE_LABELS,
  APP_TAB_DESCRIPTIONS,
  APP_TAB_IDS,
  APP_TAB_LABELS,
  APP_TABS,
  DEFAULT_TABS_BY_ROLE,
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

test("every registered tab has complete display metadata", () => {
  for (const tab of APP_TABS) {
    assert.equal(typeof tab.id, "string");
    assert.ok(tab.id.length > 0);
    assert.equal(typeof tab.label, "string");
    assert.ok(tab.label.length > 0);
    assert.equal(typeof tab.description, "string");
    assert.ok(tab.description.length > 0);
    assert.equal(typeof tab.icon, "object");
    assert.equal(APP_TAB_LABELS[tab.id], tab.label);
    assert.equal(APP_TAB_DESCRIPTIONS[tab.id], tab.description);
    assert.equal(APP_PAGE_LABELS[tab.id], tab.label);
  }
});

test("non-navigation data warnings retain a readable label", () => {
  assert.equal(APP_PAGE_LABELS.assetAlerts, "تنبيهات الأصول");
});

test("legacy role defaults reference only registered tabs", () => {
  for (const [role, ids] of Object.entries(DEFAULT_TABS_BY_ROLE)) {
    assert.ok(ids.length > 0, `${role} must keep a default page set`);
    assert.equal(new Set(ids).size, ids.length, `${role} defaults must be unique`);
    for (const id of ids) assert.ok(APP_TAB_IDS.includes(id), `${role} references unknown tab ${id}`);
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
