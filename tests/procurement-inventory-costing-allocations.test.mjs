import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const sql = await readFile(new URL("../supabase/migrations/20261123101500_procurement_inventory_costing_allocations.sql", import.meta.url), "utf8");

test("inventory valuation defaults to moving average and exposes FIFO as an option", () => {
  assert.match(sql, /valuation_method text not null default 'moving_average'/i);
  assert.match(sql, /'moving_average','fifo'/i);
  assert.match(sql, /effective_from date not null default current_date/i);
});

test("FIFO layers are opened from the activation snapshot, not historical movement replay", () => {
  assert.match(sql, /'opening:'\|\|b\.inventory_item_id::text\|\|':'\|\|b\.warehouse_id::text/i);
  assert.match(sql, /from public\.inventory_balances b[\s\S]*on conflict\(source_key\) do nothing/i);
  assert.match(sql, /new\.posted_at::date < activation_date/i);
  assert.doesNotMatch(sql, /insert into public\.inventory_fifo_layers[\s\S]*from public\.inventory_movements/i);
});

test("FIFO issue consumes oldest available layers and stores an idempotent consumption ledger", () => {
  assert.match(sql, /order by received_at,id[\s\S]*for update/i);
  assert.match(sql, /unique\(issue_movement_id,layer_id\)/i);
  assert.match(sql, /insert into public\.inventory_fifo_consumptions/i);
  assert.match(sql, /inventory_fifo_restore_reversal/i);
});

test("issue costing remains linked to the canonical project actual-cost engine", () => {
  assert.match(sql, /public\.save_project_actual_cost\(/i);
  assert.match(sql, /public\.submit_project_actual_cost\(/i);
  assert.match(sql, /public\.approve_project_actual_cost\(/i);
  assert.match(sql, /actual_cost_entry_id/i);
});

test("project allocation ledgers reference invoice lines and expenses without creating a second GL trigger", () => {
  assert.match(sql, /purchase_line_project_allocations/i);
  assert.match(sql, /expense_project_allocations/i);
  assert.match(sql, /references public\.supplier_invoice_lines\(id\)/i);
  assert.match(sql, /references public\.expenses\(id\)/i);
  assert.doesNotMatch(sql, /create trigger .*accounting_/i);
});
