import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const sql = await readFile(new URL("../supabase/migrations/20261123101500_procurement_inventory_costing_allocations.sql", import.meta.url), "utf8");
const inventoryUi = await readFile(new URL("../src/operational/InventoryWorkspace.jsx", import.meta.url), "utf8");

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

test("inventory settings UI uses protected valuation RPCs and keeps moving average as default", () => {
  assert.match(inventoryUi, /get_inventory_valuation_settings/);
  assert.match(inventoryUi, /set_inventory_valuation_method/);
  assert.match(inventoryUi, /value="moving_average"/);
  assert.match(inventoryUi, /value="fifo"/);
});

test("multi-project expenses create project actual-cost allocations without GL duplication", () => {
  assert.match(sql, /prepare_allocated_expense_actual_cost/);
  assert.match(sql, /approved_expense_allocation/);
  assert.match(sql, /Project allocations must equal the expense gross amount/);
  assert.doesNotMatch(sql, /create trigger .*accounting_expenses_gl/i);
});

test("expense cancellation reverses or rejects every allocated actual-cost entry", () => {
  assert.match(sql, /create or replace function public\.cancel_expense\(target_expense_id uuid, reason text\)/i);
  assert.match(sql, /from public\.expense_project_allocations a[\s\S]*join public\.project_actual_cost_entries c/i);
  assert.match(sql, /reverse_project_actual_cost\(allocation\.actual_cost_entry_id/);
  assert.match(sql, /reject_project_actual_cost\(allocation\.actual_cost_entry_id/);
});

test("general purchase invoice lines support exact base-currency project allocations", () => {
  assert.match(sql, /save_purchase_invoice_project_allocations/);
  assert.match(sql, /prepare_purchase_line_project_costs/);
  assert.match(sql, /Project allocations must equal invoice line total in base currency/);
  assert.match(sql, /purchase_invoice_allocation/);
});

test("warehouse transfer carries FIFO weighted unit cost and source layer lineage", () => {
  assert.match(sql, /create or replace function public\.transfer_inventory\(/);
  assert.match(sql, /out_row\.unit_cost/);
  assert.match(sql, /source_movement_id',out_row\.id/);
  assert.match(sql, /transfer:'\|\|new\.id::text/);
});

test("expense and procurement screens expose multi-project allocation entry", async () => {
  const app = await readFile(new URL("../src/AppMonolith.jsx", import.meta.url), "utf8");
  const procurement = await readFile(new URL("../src/operational/ProcurementWorkspace.jsx", import.meta.url), "utf8");
  assert.match(app, /prepare_allocated_expense_actual_cost/);
  assert.match(app, /توزيع على عدة مشروعات/);
  assert.match(procurement, /save_purchase_invoice_project_allocations/);
  assert.match(procurement, /توزيع تكلفة المشتريات العامة/);
});
