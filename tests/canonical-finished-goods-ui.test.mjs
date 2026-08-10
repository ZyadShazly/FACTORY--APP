import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const domain = readFileSync("src/domain/inventoryBalances.js", "utf8");
const hook = readFileSync("src/operational/useInventoryWorkspace.js", "utf8");
const ui = readFileSync("src/AppMonolith.jsx", "utf8");

test("finished-goods balances aggregate the canonical ledger across warehouses", () => {
  assert.match(domain, /export function aggregateInventoryByProduct/);
  assert.match(domain, /item\.item_type !== "finished_good"/);
  assert.match(domain, /current\.quantityOnHand \+= Number\(row\.quantity_on_hand/);
  assert.match(domain, /current\.inventoryValue \+= Number\(row\.inventory_value/);
  assert.match(domain, /canonicalFinishedProductAlerts/);
});

test("dashboard products sales and rentals share the live inventory read model", () => {
  assert.match(hook, /supabase\.rpc\("get_inventory_workspace"\)/);
  assert.match(hook, /table: "inventory_movements"/);
  for (const scope of ["dashboard", "products", "sales", "rentals"]) {
    assert.match(ui, new RegExp(`useInventoryWorkspace\\("${scope}"\\)`));
  }
  assert.doesNotMatch(ui, /function finishedStock/);
  assert.doesNotMatch(ui, /function producedQty/);
});

test("commercial lifecycle refreshes both documents and inventory", () => {
  assert.match(ui, /scope: "sales:post"[\s\S]*Promise\.all\(\[refresh\(\), reloadInventory\(\)\]\)/);
  assert.match(ui, /scope: "rentals:post"[\s\S]*Promise\.all\(\[refresh\(\), reloadInventory\(\)\]\)/);
  assert.match(ui, /scope: "rentals:return"[\s\S]*reloadInventory/);
});

test("dashboard counts canonical project lifecycle and completed output only", () => {
  assert.match(ui, /!\["completed", "closed", "cancelled"\]\.includes\(project\.lifecycle\)/);
  assert.match(ui, /project\.effective_progress_percentage \?\? project\.progress/);
  assert.match(ui, /order\.status === "completed" && String\(order\.completed_at/);
});
