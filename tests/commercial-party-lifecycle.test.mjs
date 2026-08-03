import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration = fs.readFileSync("supabase/migrations/20260803070000_commercial_party_lifecycle.sql", "utf8");
const ui = fs.readFileSync("src/AppMonolith.jsx", "utf8");

test("customer and supplier history cannot be hard deleted", () => {
  assert.match(migration, /if tg_op = 'DELETE'/);
  assert.match(migration, /history cannot be deleted; archive it instead/);
  assert.match(migration, /drop policy if exists customers_delete_permission/);
  assert.match(migration, /drop policy if exists suppliers_delete_permission/);
});

test("archive lifecycle is authorized, reversible, and audited", () => {
  assert.match(migration, /if not public\.can_delete_rows\(\)/);
  assert.match(migration, /Archive reason is required/);
  assert.match(migration, /new\.archived_by := auth\.uid\(\)/);
  assert.match(migration, /else\s+new\.archived_by := null/);
  assert.match(migration, /customers_archived_by_idx/);
  assert.match(migration, /suppliers_archived_by_idx/);
  assert.match(migration, /create or replace function private\.require_active_commercial_party/);
  assert.match(migration, /Archived %s cannot be used in new transactions/);
  for (const table of ["sales", "rentals", "customer_receipts", "projects", "supplier_payments", "material_purchases", "project_budget_items", "purchase_orders", "supplier_invoices", "supplier_quotes", "assets"]) {
    assert.match(migration, new RegExp(`['\"]${table}['\"]`));
  }
});

test("commercial party UI archives, restores, and excludes archived parties from new work", () => {
  assert.match(ui, /const activeSuppliers = data\.suppliers\.filter\(\(supplier\) => !supplier\.archived_at\)/);
  assert.match(ui, /const archivedSuppliers = data\.suppliers\.filter\(\(supplier\) => supplier\.archived_at\)/);
  assert.match(ui, /const activeCustomers = data\.customers\.filter\(\(customer\) => !customer\.archived_at\)/);
  assert.match(ui, /const archivedCustomers = data\.customers\.filter\(\(customer\) => customer\.archived_at\)/);
  assert.match(ui, /ArchiveSection title="الموردون المؤرشفون"/);
  assert.match(ui, /ArchiveSection title="العملاء المؤرشفون"/);
  assert.match(ui, /archived_at: new Date\(\)\.toISOString\(\)/);
  assert.match(ui, /archived_at: null/);
  assert.doesNotMatch(ui, /deleteRow\("(?:customers|suppliers)"/);
});
