import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { customerBalances } from "../src/domain/commercialBalances.js";

const journalUi = await readFile(new URL("../src/accounting/JournalWorkspace.jsx", import.meta.url), "utf8");
const app = await readFile(new URL("../src/AppMonolith.jsx", import.meta.url), "utf8");
const migration = await readFile(new URL("../supabase/migrations/20261122143000_manual_customer_journal_subledger.sql", import.meta.url), "utf8");

test("manual customer journal debit increases customer due without changing cash received", () => {
  const result = customerBalances("c1", {
    sales: [{ customer_id: "c1", status: "posted", total: 1000 }],
    rentals: [], projects: [], customerReceipts: [], customerAdjustments: [],
    customerManualJournalLines: [{ customer_id: "c1", debit: 250, credit: 0 }],
  });
  assert.equal(result.due, 1250);
  assert.equal(result.cashReceived, 0);
});

test("manual customer journal credit reduces customer due", () => {
  const result = customerBalances("c1", {
    sales: [{ customer_id: "c1", status: "posted", total: 1000 }],
    rentals: [], projects: [], customerReceipts: [], customerAdjustments: [],
    customerManualJournalLines: [{ customer_id: "c1", debit: 0, credit: 300 }],
  });
  assert.equal(result.due, 700);
});

test("journal editor persists customer partner id and restores it when editing", () => {
  assert.match(journalUi, /العميل المرتبط بالسطر/);
  assert.match(journalUi, /partner_type:line\.partner_id\?"customer":null/);
  assert.match(journalUi, /partner_id:line\.partner_id\|\|null/);
  assert.match(journalUi, /partner_type:line\.partner_type\|\|""/);
  assert.match(journalUi, /partner_id:line\.partner_id\|\|""/);
});

test("customer workspace includes manual journal lines in balances and statement", () => {
  assert.match(app, /get_customer_manual_journal_lines/);
  assert.match(app, /customerManualJournalLines/);
  assert.match(app, /manualJournals/);
});

test("manual customer journal posting is limited to receivables and preserves legacy records", () => {
  assert.match(migration, /accounting_resolve_mapping\('accounts_receivable','global',''\)/);
  assert.match(migration, /entry_origin='manual'/);
  assert.match(migration, /source_module is null/);
  assert.match(migration, /partner_type='customer'/);
  assert.match(migration, /Active customer required/);
});
