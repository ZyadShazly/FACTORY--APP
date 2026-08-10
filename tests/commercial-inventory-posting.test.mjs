import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/202608102100_commercial_inventory_posting.sql", "utf8");
const ui = readFileSync("src/AppMonolith.jsx", "utf8");

test("sale and rental creation use authenticated retry-safe RPCs", () => {
  assert.match(migration, /create or replace function public\.post_sale\(/);
  assert.match(migration, /create or replace function public\.post_rental\(/);
  assert.match(migration, /private\.commercial_page_allowed\('sales'\)/);
  assert.match(migration, /private\.commercial_page_allowed\('rentals'\)/);
  assert.match(migration, /sales_command_uidx/);
  assert.match(migration, /rentals_command_uidx/);
  assert.match(migration, /revoke insert on table public\.sales from anon,authenticated/);
  assert.match(migration, /revoke insert on table public\.rentals from anon,authenticated/);
  assert.match(migration, /grant execute on function public\.post_sale[\s\S]*to authenticated/);
  assert.match(migration, /grant execute on function public\.post_rental[\s\S]*to authenticated/);
});

test("commercial posting consumes canonical finished-goods inventory atomically", () => {
  assert.match(migration, /item_type='finished_good'/);
  assert.match(migration, /from public\.inventory_balances b[\s\S]*for update/);
  assert.match(migration, /movement_type[\s\S]*'sale_issue'/);
  assert.match(migration, /movement_type[\s\S]*'rental_issue'/);
  assert.match(migration, /Insufficient finished-goods inventory/);
  assert.match(migration, /'sale_issue',output_item/);
  assert.match(migration, /'rental_issue',output_item/);
});

test("commercial lifecycle restores each issued inventory movement once", () => {
  assert.match(migration, /private\.reverse_commercial_inventory/);
  assert.match(migration, /where reversal\.reversed_movement_id=original\.id/);
  assert.match(migration, /'sale_issue_reversal'/);
  assert.match(migration, /'rental_return'/);
  assert.match(migration, /'rental_cancellation'/);
  assert.match(migration, /perform private\.reverse_commercial_inventory\('sale'/);
  assert.match(migration, /perform private\.reverse_commercial_inventory\('rental'/);
});

test("commercial UI posts through RPC and reads canonical inventory balances", () => {
  assert.match(ui, /supabase\.rpc\("post_sale"/);
  assert.match(ui, /supabase\.rpc\("post_rental"/);
  assert.doesNotMatch(ui, /insertRow\("sales"/);
  assert.doesNotMatch(ui, /insertRow\("rentals"/);
  assert.match(ui, /aggregateInventoryByProduct/);
  assert.match(ui, /finishedBalances\.get\(form\.productId\)\?\.quantityOnHand/);
  assert.match(ui, /\.eq\("command_id", commandId\)/);
});
