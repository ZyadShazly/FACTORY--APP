import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync("supabase/migrations/202608103500_production_financial_data_boundary.sql","utf8");
const app=fs.readFileSync("src/AppMonolith.jsx","utf8");

test("production reference and workspace payloads remove financial fields",()=>{
  assert.match(migration,/get_production_reference_data/);
  for(const field of ["materials_cost","labor_cost","overhead_cost","total_cost","unit_cost","selling_price","inventory_value","value_delta"]){
    assert.match(migration,new RegExp(`'${field}'`));
  }
  assert.match(migration,/assigned_employee_id=actor_employee/);
  assert.match(migration,/current_identity_role\(\)<>\'production\'/);
});

test("production cannot select finance-bearing base rows directly",()=>{
  for(const table of ["materials","products","production_orders"]){
    assert.match(migration,new RegExp(`operational_${table}_select`));
  }
  assert.match(migration,/current_identity_role\(\) in \('owner','manager','accountant'\)/);
});

test("read-only product view hides every cost and price column",()=>{
  assert.match(app,/hideProfitInfo \? \[\] : \["تكلفة الخامات", "عمالة", "تكاليف غير مباشرة", "إجمالي التكلفة\/وحدة", "سعر البيع", "الهامش"\]/);
  assert.match(app,/hideProfitInfo\?"المنتجات وتركيبة التصنيع"/);
});
