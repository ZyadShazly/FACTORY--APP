import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration = fs.readFileSync(
  "supabase/migrations/20260928190335_accounting_foundation.sql",
  "utf8",
);

test("accounting foundation creates only additive accounting tables", () => {
  for (const table of [
    "accounting_accounts",
    "accounting_journal_entries",
    "accounting_journal_lines",
    "accounting_journal_revisions",
    "accounting_account_mappings",
    "accounting_source_links",
    "accounting_settings",
    "accounting_periods",
  ]) {
    assert.match(migration, new RegExp(`create table public\\.${table}\\s*\\(`, "i"));
  }

  assert.doesNotMatch(migration, /drop\s+table/i);
  assert.doesNotMatch(migration, /truncate\s+/i);
  assert.doesNotMatch(migration, /delete\s+from\s+public\./i);
  assert.doesNotMatch(migration, /alter\s+table\s+public\.(sales|expenses|supplier_invoices|supplier_payments|customer_receipts|inventory_movements|projects|payroll|daily_labor)\b/i);
});

test("chart of accounts remains user-expandable and cycle-safe", () => {
  assert.match(migration, /parent_id uuid references public\.accounting_accounts\(id\)/);
  assert.match(migration, /accounting_guard_account_hierarchy/);
  assert.match(migration, /Circular account hierarchy is not allowed/);
  assert.match(migration, /is_posting boolean not null default true/);
  assert.match(migration, /is_active boolean not null default true/);
});

test("journal lines enforce one-sided amounts and posting-account safety", () => {
  assert.match(migration, /accounting_journal_lines_amount_side_check/);
  assert.match(migration, /\(debit > 0 and credit = 0\) or \(credit > 0 and debit = 0\)/);
  assert.match(migration, /Group account cannot receive journal postings/);
  assert.match(migration, /Inactive account cannot receive journal postings/);
});

test("posted journals are database-enforced as balanced", () => {
  assert.match(migration, /accounting_assert_entry_balanced/);
  assert.match(migration, /debit_total <> credit_total/);
  assert.match(migration, /deferrable initially deferred/);
  assert.match(migration, /accounting_journal_entries_balance_guard/);
  assert.match(migration, /accounting_journal_lines_balance_guard/);
});

test("owner override audit foundation is present without mutating balances separately", () => {
  assert.match(migration, /revision_number integer not null default 1/);
  assert.match(migration, /master_overridden boolean not null default false/);
  assert.match(migration, /accounting_journal_revisions/);
  assert.match(migration, /header_before jsonb not null/);
  assert.match(migration, /lines_before jsonb not null/);
  assert.doesNotMatch(migration, /\bbalance\s+numeric/i);
});

test("source idempotency and historical activation controls are modeled", () => {
  assert.match(migration, /accounting_source_links_source_uidx/);
  assert.match(migration, /source_revision integer not null default 1/);
  assert.match(migration, /activation_date date/);
  assert.match(migration, /enabled boolean not null default false/);
});

test("accounting tables are deny-by-default at the Data API boundary", () => {
  for (const table of [
    "accounting_accounts",
    "accounting_journal_entries",
    "accounting_journal_lines",
    "accounting_journal_revisions",
    "accounting_account_mappings",
    "accounting_source_links",
    "accounting_settings",
    "accounting_periods",
  ]) {
    assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`, "i"));
    assert.match(migration, new RegExp(`revoke all on table public\\.${table} from anon, authenticated`, "i"));
  }
});
