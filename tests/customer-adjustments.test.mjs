import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { customerBalances } from "../src/domain/commercialBalances.js";

const migration = await readFile(
  new URL("../supabase/migrations/20260922140000_customer_non_cash_adjustments.sql", import.meta.url),
  "utf8",
);
const panel = await readFile(
  new URL("../src/operational/CustomerAdjustmentsPanel.jsx", import.meta.url),
  "utf8",
);
const app = await readFile(new URL("../src/AppMonolith.jsx", import.meta.url), "utf8");

test("non-cash customer adjustment reduces AR without increasing cash received", () => {
  const result = customerBalances("c1", {
    sales: [{ customer_id: "c1", status: "posted", total: 50000 }],
    rentals: [],
    projects: [],
    customerReceipts: [{ customer_id: "c1", status: "posted", amount: 1000, transaction_classification: "settlement", settlement_amount: 1000, allocated_advance_amount: 0 }],
    customerAdjustments: [{ customer_id: "c1", status: "posted", amount: 2000 }],
  });
  assert.equal(result.due, 47000);
  assert.equal(result.cashReceived, 1000);
});

test("reversed customer adjustment no longer reduces AR", () => {
  const result = customerBalances("c1", {
    sales: [{ customer_id: "c1", status: "posted", total: 50000 }],
    rentals: [],
    projects: [],
    customerReceipts: [],
    customerAdjustments: [{ customer_id: "c1", status: "reversed", amount: 2000 }],
  });
  assert.equal(result.due, 50000);
});

test("customer adjustment is protected, reversible, auditable and cannot exceed due", () => {
  assert.match(migration, /create table if not exists public\.customer_adjustments/);
  assert.match(migration, /record_customer_adjustment/);
  assert.match(migration, /reverse_customer_adjustment/);
  assert.match(migration, /Adjustment cannot exceed current customer due/);
  assert.match(migration, /customer_adjustment_posted/);
  assert.match(migration, /customer_adjustment_reversed/);
  assert.match(migration, /non_cash/);
  assert.match(migration, /from public\.customer_adjustments ca/);
});

test("customer UI separates non-cash adjustments from cash receipts", () => {
  assert.match(panel, /تسويات وخصومات العميل/);
  assert.match(panel, /لا تُسجل كتحصيل نقدي/);
  assert.match(panel, /record_customer_adjustment/);
  assert.match(panel, /reverse_customer_adjustment/);
  assert.match(app, /CustomerAdjustmentsPanel/);
  assert.match(app, /تسوية عميل/);
});
