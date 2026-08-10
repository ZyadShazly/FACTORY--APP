import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const app=fs.readFileSync("src/AppMonolith.jsx","utf8");
const migration=fs.readFileSync("supabase/migrations/202608101500_uat_sale_positive_unit_price.sql","utf8");

test("UAT-003 rejects unit_price <= 0 in UI and database while preserving legacy rows",()=>{
  assert.match(app,/unitPrice <= 0/);
  assert.match(migration,/unit_price>0/);
  assert.match(migration,/new\.unit_price<=0/);
  assert.match(migration,/not valid/);
  assert.doesNotMatch(migration,/update public\.sales/);
  assert.doesNotMatch(migration,/delete from public\.sales/);
});
