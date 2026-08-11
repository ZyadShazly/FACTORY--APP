import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const ui = fs.readFileSync("src/operational/ProductionWorkspace.jsx", "utf8");
const migration = fs.readFileSync("supabase/migrations/20260720094749_secure_production_create.sql", "utf8");

test("UAT-008 rejects invalid, non-positive quantity and negative waste without coercion", () => {
  assert.match(ui, /!Number\.isFinite\(quantity\)\|\|quantity<=0/);
  assert.match(ui, /!Number\.isFinite\(waste\)/);
  assert.match(ui, /if\(waste<0\)/);
  assert.doesNotMatch(ui, /target_waste_percentage:Number\(form\.waste\|\|0\)/);
  assert.match(migration, /target_quantity is null or target_quantity<=0/);
  assert.match(migration, /coalesce\(target_waste_percentage,0\)<0/);
});
