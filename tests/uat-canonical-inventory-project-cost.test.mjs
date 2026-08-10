import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { aggregateInventoryByMaterial, canonicalMaterialAlerts } from "../src/domain/inventoryBalances.js";

const app = fs.readFileSync("src/AppMonolith.jsx", "utf8");
const inventoryHook = fs.readFileSync("src/operational/useInventoryWorkspace.js", "utf8");
const projects = fs.readFileSync("src/v22/projectWorkspace.jsx", "utf8");
const actualCost = fs.readFileSync("src/v22/projectActualCost.jsx", "utf8");
const migration = fs.readFileSync("supabase/migrations/202608101100_uat_canonical_project_actual_cost.sql", "utf8");

test("UAT-001 aggregates the protected ledger across warehouses", () => {
  const workspace = {
    items: [{ id: "i1", material_id: "m1", name: "MDF", unit: "لوح" }],
    materials: [{ id: "m1", name: "MDF" }, { id: "m2", name: "قديم" }],
    unlinked_materials: [{ id: "m2", name: "قديم" }],
    balances: [
      { inventory_item_id: "i1", warehouse_name: "A", quantity_on_hand: 4 },
      { inventory_item_id: "i1", warehouse_name: "B", quantity_on_hand: 7 },
    ],
  };
  assert.equal(aggregateInventoryByMaterial(workspace).get("m1").quantityOnHand, 11);
  const alerts = canonicalMaterialAlerts(workspace, 12);
  assert.equal(alerts.low[0].quantityOnHand, 11);
  assert.deepEqual(alerts.low[0].warehouseNames, ["A", "B"]);
  assert.equal(alerts.unlinked[0].id, "m2");
  assert.match(app, /useInventoryWorkspace\("dashboard"\)/);
  assert.match(inventoryHook, /supabase\.rpc\("get_inventory_workspace"\)/);
  assert.doesNotMatch(app, /function materialStock/);
});

test("UAT-002 uses approved entries and treats the project column as cache", () => {
  assert.match(migration, /entry\.status = 'approved'/);
  assert.match(migration, /private\.project_approved_actual_cost\(p\.id\)/);
  assert.match(migration, /get_project_actual_cost_reconciliation/);
  assert.match(migration, /get_project_cost_variance_snapshot_canonical/);
  assert.match(actualCost, /get_project_cost_variance_snapshot_canonical/);
  assert.match(projects, /const actual = number\(project\.actual_cost\)/);
  assert.doesNotMatch(projects, /summary\.costs\.filter/);
});

test("UAT-014 hides the placeholder project report tab", () => {
  assert.doesNotMatch(projects, /\["reports"/);
  assert.doesNotMatch(projects, /tab === "reports" && <ComingSoon/);
});
