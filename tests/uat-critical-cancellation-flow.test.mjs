import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const app=fs.readFileSync("src/AppMonolith.jsx","utf8");
const production=fs.readFileSync("src/operational/ProductionWorkspace.jsx","utf8");
const inventory=fs.readFileSync("src/operational/InventoryWorkspace.jsx","utf8");
const opening=fs.readFileSync("src/operational/OpeningInventoryPanel.jsx","utf8");
const actualCost=fs.readFileSync("src/v22/projectActualCost.jsx","utf8");
const shared=fs.readFileSync("src/v22/shared.jsx","utf8");
const migration=fs.readFileSync("supabase/migrations/20260810133000_uat_idempotent_production_cancellation.sql","utf8");

test("UAT-007 critical cancellation avoids browser-native dialogs",()=>{
  assert.doesNotMatch(app.slice(app.indexOf("function SalesTab"),app.indexOf("/* -------------------------------- Suppliers")),/window\.(?:prompt|confirm)/);
  assert.doesNotMatch(production,/window\.prompt\(`اكتب سبب إلغاء/);
  assert.doesNotMatch(inventory,/window\.confirm/);
  assert.doesNotMatch(opening,/window\.confirm/);
  assert.doesNotMatch(actualCost,/window\.prompt/);
  assert.match(app,/runCriticalMutation\(\{ scope:"sales:cancel"/);
  assert.match(production,/scope:"production:cancel"/);
  assert.match(shared,/reasonRequired/);
  assert.match(shared,/aria-modal="true"/);
});

test("production cancellation is idempotent and audits final state plus reversals",()=>{
  assert.match(migration,/if old_row\.status='cancelled' then return to_jsonb\(old_row\)/);
  assert.match(migration,/'source_status',old_row\.status/);
  assert.match(migration,/'final_status',saved\.status/);
  assert.match(migration,/'reversal_references'/);
  assert.doesNotMatch(migration,/delete from public\.production_orders/);
});
