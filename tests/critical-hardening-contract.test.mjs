import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const app = fs.readFileSync('src/App.jsx', 'utf8');
const production = fs.readFileSync('src/operational/ProductionWorkspace.jsx', 'utf8');
const inventory = fs.readFileSync('src/operational/InventoryWorkspace.jsx', 'utf8');
const materials = fs.readFileSync('src/operational/MaterialsCatalogWorkspace.jsx', 'utf8');

test('production UI no longer reads or mutates production_orders directly', () => {
  const runtime = `${app}\n${production}`;
  assert.doesNotMatch(runtime, /from\(["']production_orders["']\)/);
  assert.doesNotMatch(production, /insertRow\(["']productionOrders|updateRow\(["']productionOrders|deleteRow\(["']productionOrders/);
});

test('production UI uses protected workspace and action RPCs', () => {
  assert.match(production, /get_production_workspace/);
  assert.match(production, /create_production_order_secure/);
  assert.match(production, /issue_production_material/);
  assert.match(production, /update_production_operation_status/);
});

test('inventory UI reads the canonical ledger workspace', () => {
  assert.match(inventory, /get_inventory_workspace/);
  assert.doesNotMatch(inventory, /materialStock|finishedStock|initial_stock/);
});

test('legacy direct material purchase path is absent from the active material workspace', () => {
  assert.doesNotMatch(materials, /materialPurchases|تسجيل عملية شراء|addPurchase/);
  assert.match(materials, /طلب شراء/);
});
