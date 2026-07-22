import assert from "node:assert/strict";
import test from "node:test";

import { permissionsForProfile } from "../src/app/permissions.js";
import { APP_TAB_IDS } from "../src/app/navigationRegistry.js";

test("administrative roles retain every registered page and full legacy controls", () => {
  for (const role of ["owner", "manager"]) {
    const resolved = permissionsForProfile({ role, status: "active", permissions: {} });
    assert.deepEqual(resolved.pages, APP_TAB_IDS);
    assert.equal(resolved.can_delete, true);
    assert.equal(resolved.view_financials, true);
    assert.equal(resolved.can_create_products, true);
    assert.equal(resolved.can_edit_products, true);
  }
});

test("production pages stay bounded to the production allow-list", () => {
  const resolved = permissionsForProfile({
    role: "production",
    status: "active",
    permissions: { pages: ["production", "assets", "payroll", "settings"] },
  });

  assert.ok(resolved.pages.includes("projects"));
  assert.ok(resolved.pages.includes("production"));
  assert.ok(!resolved.pages.includes("payroll"));
  assert.ok(!resolved.pages.includes("settings"));
  assert.equal(resolved.view_financials, false);
  assert.equal(resolved.can_delete, false);
});

test("accountant defaults remain backward compatible and settings stays owner-managed", () => {
  const resolved = permissionsForProfile({ role: "accountant", status: "active", permissions: {} });
  assert.ok(resolved.pages.includes("projects"));
  assert.ok(resolved.pages.includes("payroll"));
  assert.ok(!resolved.pages.includes("settings"));
  assert.equal(resolved.can_create_products, true);
  assert.equal(resolved.can_edit_products, false);
});

test("explicit action permissions add their matching modules without duplicates", () => {
  const resolved = permissionsForProfile({
    role: "accountant",
    status: "active",
    permissions: {
      pages: ["projects"],
      assets_view: true,
      payroll_calendar_view: true,
      audit_log_view: true,
    },
  });

  assert.deepEqual(
    resolved.pages.filter((page) => ["projects", "assets", "workCalendar", "auditLog"].includes(page)),
    ["projects", "assets", "workCalendar", "auditLog"],
  );
  assert.equal(new Set(resolved.pages).size, resolved.pages.length);
});
