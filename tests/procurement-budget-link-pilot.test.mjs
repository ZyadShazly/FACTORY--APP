import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const ui = await readFile(new URL("../src/operational/ProcurementWorkspace.jsx", import.meta.url), "utf8");
const migration = await readFile(new URL("../supabase/migrations/20260910211606_fix_procurement_budget_link.sql", import.meta.url), "utf8");

test("project purchase requests explicitly choose an approved budget item", () => {
  assert.match(ui, /get_procurement_budget_items/);
  assert.match(ui, /budget_item_id/);
  assert.match(ui, /budget_item_id:budgetItem/);
  assert.match(ui, /خارج الميزانية — يتطلب تجاوز Owner/);
});

test("unlinked and stale budget links require owner override", () => {
  assert.match(migration, /unlinked_budget_item/);
  assert.match(migration, /invalid_budget_link/);
  assert.match(migration, /purchase_request_budget_variances/);
  assert.match(migration, /get_procurement_budget_items/);
});
