import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const directory = "supabase/migrations";
const files = fs.readdirSync(directory).filter((file) => file.endsWith(".sql")).sort();
const baseline = fs.readFileSync(`${directory}/20260711165136_legacy_erp_baseline.sql`, "utf8");
const closeout = fs.readFileSync(`${directory}/20260811080000_migration_chain_security_closeout.sql`, "utf8");

test("migration versions are canonical, unique, and start at the real baseline", () => {
  assert.equal(files[0], "20260711165136_legacy_erp_baseline.sql");
  assert.ok(files.every((file) => /^\d{14}_[a-z0-9_]+\.sql$/.test(file)));
  assert.equal(new Set(files.map((file) => file.slice(0, 14))).size, files.length);
});

test("baseline defines the historical operational schema without application data", () => {
  for (const table of [
    "profiles", "suppliers", "customers", "materials", "material_purchases",
    "products", "production_orders", "sales", "rentals", "supplier_payments",
    "customer_receipts", "expenses",
  ]) {
    assert.match(baseline, new RegExp(`create\\s+table\\s+public\\.${table}\\s*\\(`, "i"));
  }
  assert.match(baseline, /item_type\s+text\s+not null default 'sale'/i);
  assert.match(baseline, /waste_percentage\s+numeric\s+not null default 0/i);
  assert.doesNotMatch(baseline, /\binsert\s+into\s+public\./i);
});

test("baseline enables RLS and uses explicit API grants", () => {
  assert.match(baseline, /enable row level security/i);
  assert.match(baseline, /revoke all on table public\.%I from anon, authenticated/i);
  assert.match(baseline, /grant select, insert, update, delete on table public\.%I to authenticated/i);
  assert.match(baseline, /revoke all on function public\.is_manager\(\) from public, anon/i);
});

test("fresh-chain internal trigger helpers are not executable API functions", () => {
  assert.match(closeout, /drop policy if exists profiles_update_own/i);
  for (const helper of [
    "apply_inventory_movement",
    "record_purchase_request_status_change",
    "complete_purchase_request_from_order",
  ]) {
    assert.match(
      closeout,
      new RegExp(`revoke all on function private\\.${helper}\\(\\)[\\s\\S]*from public, anon, authenticated`, "i"),
    );
  }
});
