import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const migration = fs.readFileSync("supabase/migrations/202608102000_asset_maintenance_workflow.sql", "utf8");
const ui = fs.readFileSync("src/assets/AssetsPage.jsx", "utf8");
const realtime = fs.readFileSync("src/realtime.js", "utf8");

test("maintenance orders have a strict auditable lifecycle", () => {
  assert.match(migration, /create table if not exists public\.asset_maintenance_orders/);
  assert.match(migration, /status text not null default 'open' check \(status in \('open', 'completed', 'cancelled'\)\)/);
  assert.match(migration, /asset_maintenance_one_open_per_asset_idx/);
  assert.match(migration, /previous_operational_status/);
  assert.match(migration, /cancellation_reason/);
  assert.match(migration, /audit_changes after insert or update or delete/);
});

test("opening maintenance is serialized and removes only fully available assets", () => {
  assert.match(migration, /from public\.assets where id = \(payload->>'asset_id'\)::uuid for update/);
  assert.match(migration, /assigned_quantity <> 0 or asset_row\.available_quantity <> asset_row\.total_quantity/);
  assert.match(migration, /'maintenance_started', asset_row\.total_quantity, -asset_row\.total_quantity/);
  assert.match(migration, /operational_status = 'under_maintenance'/);
});

test("completion and cancellation restore availability exactly once", () => {
  assert.match(migration, /Only an open maintenance order may be completed/);
  assert.match(migration, /'maintenance_completed', asset_row\.total_quantity, asset_row\.total_quantity/);
  assert.match(migration, /Only an open maintenance order may be cancelled/);
  assert.match(migration, /'reversed', asset_row\.total_quantity, asset_row\.total_quantity/);
  assert.match(migration, /saved\.previous_operational_status/);
});

test("maintenance writes are RPC-only and status cannot bypass the workflow", () => {
  assert.match(migration, /revoke all on table public\.asset_maintenance_orders from anon, authenticated/);
  assert.match(migration, /revoke all on function public\.open_asset_maintenance\(jsonb\) from public, anon/);
  assert.match(migration, /Maintenance status may only change through the maintenance workflow/);
  assert.match(migration, /assets_manage permission required/);
});

test("the Assets UI completes the operational flow and retains history", () => {
  assert.match(ui, /open_asset_maintenance/);
  assert.match(ui, /complete_asset_maintenance/);
  assert.match(ui, /cancel_asset_maintenance/);
  assert.match(ui, /أوامر الصيانة النشطة/);
  assert.match(ui, /سجل الصيانة المكتملة والملغاة/);
  assert.doesNotMatch(ui, /الصيانة المتقدمة مؤجلة، وتعرض هذه المرحلة الحالات الأساسية فقط/);
});

test("maintenance orders participate in bootstrap and Realtime", () => {
  assert.match(realtime, /asset_maintenance_orders: "assetMaintenanceOrders"/);
  assert.match(realtime, /"assetMaintenanceOrders"/);
});
