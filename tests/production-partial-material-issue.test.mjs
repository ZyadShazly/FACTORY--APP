import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const ui=fs.readFileSync("src/operational/ProductionWorkspace.jsx","utf8");
const migration=fs.readFileSync("supabase/migrations/20260727053000_production_partial_material_issue.sql","utf8");

test("production UI supports partial and repeated issue entry",()=>{
  assert.match(ui,/صرف الآن/);
  assert.match(ui,/تسجيل الصرف/);
  assert.match(ui,/المطلوب/);
  assert.match(ui,/المصروف/);
  assert.match(ui,/المتبقي/);
  assert.match(ui,/\["released","in_progress"\]\.includes\(o\.status\)/);
  assert.doesNotMatch(ui,/صرف كامل/);
  assert.doesNotMatch(ui,/Number\(r\.issued_quantity\)===0/);
});

test("database accepts positive partial issue up to remaining quantity",()=>{
  assert.match(migration,/remaining:=req\.required_quantity-req\.issued_quantity/);
  assert.match(migration,/issue_quantity>remaining/);
  assert.match(migration,/issued_quantity=issued_quantity\+issue_quantity/);
  assert.doesNotMatch(migration,/Full required quantity must be issued exactly once/);
  assert.doesNotMatch(migration,/req\.inventory_movement_id is not null or req\.issued_quantity<>0/);
});

test("every production issue batch has immutable traceability",()=>{
  assert.match(migration,/create table if not exists public\.production_material_issues/);
  assert.match(migration,/inventory_movement_id uuid not null unique/);
  assert.match(migration,/production_material_issue_history is immutable/i);
  assert.match(migration,/production_material_partial_issue/);
});

test("cancellation reverses all partial issue movements",()=>{
  assert.match(migration,/from public\.production_material_issues i/);
  assert.match(migration,/select distinct x\.inventory_movement_id/);
  assert.match(migration,/reverse_inventory_movement\(movement_id,reason\)/);
});
