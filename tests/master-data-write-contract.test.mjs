import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/202608102300_master_data_write_contract.sql", "utf8");
const ui = readFileSync("src/AppMonolith.jsx", "utf8");

test("master data creation and editing are permission checked and audited", () => {
  assert.match(migration, /private\.master_data_action_allowed/);
  for (const name of ["save_product", "save_customer", "save_supplier"]) {
    assert.match(migration, new RegExp(`create or replace function public\\.${name}`));
    assert.match(migration, new RegExp(`grant execute on function[\\s\\S]*public\\.${name}`));
  }
  assert.match(migration, /revoke insert,update,delete on table public\.products,public\.customers,public\.suppliers/);
  assert.match(migration, /product_created/);
  assert.match(migration, /customer_created/);
  assert.match(migration, /supplier_created/);
});

test("new product BOM and financial inputs are validated on the server", () => {
  assert.match(migration, /At least one BOM component is required/);
  assert.match(migration, /Every BOM component requires a valid material and positive quantity/);
  assert.match(migration, /A material cannot appear twice in the same BOM/);
  assert.match(migration, /Product financial values cannot be negative/);
  assert.match(migration, /item_type in \('sale','rental','both'\)/);
  assert.doesNotMatch(migration, /update public\.products set item_type='sale'/);
});

test("master data creation is retry safe and archive dialogs are application native", () => {
  assert.match(migration, /products_command_uidx/);
  assert.match(migration, /customers_command_uidx/);
  assert.match(migration, /suppliers_command_uidx/);
  assert.match(ui, /supabase\.rpc\("save_product"/);
  assert.match(ui, /supabase\.rpc\("save_customer"/);
  assert.match(ui, /supabase\.rpc\("save_supplier"/);
  assert.match(ui, /supabase\.rpc\("set_product_archived"/);
  assert.match(ui, /supabase\.rpc\("set_commercial_party_archived"/);
  assert.doesNotMatch(ui, /window\.prompt/);
});
