import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/20260810240000_material_definition_contract.sql", "utf8");
const ui = readFileSync("src/operational/MaterialsCatalogWorkspace.jsx", "utf8");
const app = readFileSync("src/AppMonolith.jsx", "utf8");

test("material definitions are created through an owner-manager audited RPC", () => {
  assert.match(migration, /create or replace function public\.create_material_definition/);
  assert.match(migration, /private\.inventory_manage_allowed\(\)/);
  assert.match(migration, /materials_command_uidx/);
  assert.match(migration, /'materials',saved\.id::text,'material_created'/);
  assert.match(migration, /revoke insert,update,delete on table public\.materials from anon,authenticated/);
  assert.match(migration, /grant execute on function public\.create_material_definition[\s\S]*to authenticated/);
});

test("material catalog uses protected retry-safe creation and native dialogs", () => {
  assert.match(ui, /supabase\.rpc\("create_material_definition"/);
  assert.match(ui, /\.eq\("command_id",currentCommand\)/);
  assert.match(ui, /<ConfirmDialog/);
  assert.match(ui, /itemAction&&<Panel/);
  assert.doesNotMatch(ui, /window\.prompt|window\.confirm/);
  assert.doesNotMatch(app, /async function insertRow|async function updateRow|async function deleteRow/);
});

test("accountants receive an honest read-only material catalog", () => {
  assert.match(app, /<MaterialsTab[\s\S]*canManage=\{isAdministrativeRole\(role\)\}/);
  assert.match(ui, /!canManage&&<Notice/);
  assert.match(ui, /canManage&&!linked/);
  assert.match(ui, /canManage&&<Button tone="danger"/);
});
