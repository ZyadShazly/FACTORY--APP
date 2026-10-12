import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ui=readFileSync("src/assets/AssetsPage.jsx","utf8");
const migration=readFileSync("supabase/migrations/20260810310000_asset_descriptive_update_contract.sql","utf8");

test("asset registry exposes protected descriptive editing without changing ledger quantities",()=>{
  assert.match(ui,/rpc\("update_asset_record"/);
  assert.match(ui,/تعديل البيانات/);
  assert.match(ui,/disabled=\{\(editing&&!suAdmin\)\|\|form\.tracking_mode==="serialized"\}/);
  assert.match(ui,/function AssetModal\(\{[^)]*suAdmin=false\}\)/);
  assert.match(ui,/suAdmin=\{suAssetAdmin\}/);
  assert.match(ui,/rpc\("su_update_asset_details"/);
  assert.match(ui,/disabled=\{editing&&!suAdmin\} value=\{form\.purchase_cost/);
  assert.match(ui,/disabled=\{editing&&!suAdmin\} value=\{form\.unit/);
  assert.doesNotMatch(migration,/set[\s\S]*operational_status=/i);
  assert.doesNotMatch(migration,/set[\s\S]*current_location_id=/i);
  assert.match(migration,/Quantity, location and operational status require ledger-backed workflows/);
});

test("asset categories and locations can be disabled and restored",()=>{
  assert.match(ui,/async function toggleCategory/);
  assert.match(ui,/async function toggleLocation/);
  assert.match(ui,/c\.is_active\?"تعطيل":"تفعيل"/);
  assert.match(ui,/l\.is_active\?"تعطيل":"تفعيل"/);
});
