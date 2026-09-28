import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration = fs.readFileSync(
  "supabase/migrations/20260928192958_accounting_journal_core.sql",
  "utf8",
);

test("journal core exposes protected draft, post, master edit and reversal RPCs", () => {
  for (const signature of [
    /create or replace function public\.get_accounting_journal_workspace\(/,
    /create or replace function public\.create_accounting_journal\(payload jsonb\)/,
    /create or replace function public\.update_accounting_journal_draft\(target_id uuid,payload jsonb\)/,
    /create or replace function public\.post_accounting_journal\(target_id uuid\)/,
    /create or replace function public\.owner_edit_posted_accounting_journal\(/,
    /create or replace function public\.reverse_accounting_journal\(/,
  ]) {
    assert.match(migration, signature);
  }
});

test("posting requires enabled accounting, activation date and one open period", () => {
  assert.match(migration, /Accounting is not enabled/);
  assert.match(migration, /Accounting activation date is required/);
  assert.match(migration, /Journal date cannot precede the accounting activation date/);
  assert.match(migration, /An open accounting period is required for this journal date/);
  assert.match(migration, /Journal date matches multiple open accounting periods/);
  assert.match(migration, /accounting_assert_entry_balanced\(target_id\)/);
});

test("owner posted edit changes current journal lines and stores a revision", () => {
  assert.match(migration, /public\.current_identity_role\(\)<>'owner'/);
  assert.match(migration, /Owner role required to edit a posted journal/);
  assert.match(migration, /accounting_replace_lines\(target_id,payload->'lines',true,before_lines\)/);
  assert.match(migration, /revision_number=new_revision/);
  assert.match(migration, /master_overridden=true/);
  assert.match(migration, /insert into public\.accounting_journal_revisions/);
  assert.match(migration, /accounting_posted_journal_master_edited/);
});

test("failed or new postings cannot silently use inactive or group accounts", () => {
  assert.match(migration, /Inactive or group account cannot receive a new journal posting/);
  assert.match(migration, /accounting_allow_legacy_posting_account/);
  assert.match(migration, /previous->>'account_id'=account_value::text/);
});

test("reversal uses the current stored journal lines after any owner override", () => {
  const reversal = migration.slice(migration.indexOf("create or replace function private.reverse_accounting_journal_current_lines"));
  assert.match(reversal, /from public\.accounting_journal_lines l[\s\S]*where l\.journal_entry_id=current_row\.id/);
  assert.match(reversal, /reversal_row\.id,l\.line_number,l\.account_id,l\.credit,l\.debit/);
  assert.match(reversal, /set status='reversed',reversed_by_entry_id=reversal_row\.id/);
});

test("system-generated journals cannot be manually reversed out of sync with source", () => {
  assert.match(migration, /System-generated journal must be reversed from its original NextEP transaction/);
  assert.match(migration, /origin_value='system'/);
});

test("journal numbering is transactional by fiscal year", () => {
  assert.match(migration, /private\.accounting_journal_counters/);
  assert.match(migration, /fiscal_year integer primary key/);
  assert.match(migration, /update private\.accounting_journal_counters[\s\S]*returning next_number-1 into allocated/);
  assert.match(migration, /JE.*OB.*RV/s);
});

test("journal RPCs are not callable by anon or PUBLIC", () => {
  for (const fn of [
    "get_accounting_journal_workspace\\(date,date\\)",
    "create_accounting_journal\\(jsonb\\)",
    "update_accounting_journal_draft\\(uuid,jsonb\\)",
    "post_accounting_journal\\(uuid\\)",
    "owner_edit_posted_accounting_journal\\(uuid,jsonb,text\\)",
    "reverse_accounting_journal\\(uuid,date,text\\)",
  ]) {
    assert.match(migration, new RegExp(`revoke all on function public\\.${fn} from public,anon`));
    assert.match(migration, new RegExp(`grant execute on function public\\.${fn} to authenticated`));
  }
});

test("journal core remains additive to existing operational modules", () => {
  assert.doesNotMatch(migration, /drop\s+table/i);
  assert.doesNotMatch(migration, /truncate\s+/i);
  assert.doesNotMatch(migration, /delete\s+from\s+public\.(sales|expenses|supplier_invoices|inventory_movements|payroll|daily_labor)/i);
  assert.doesNotMatch(migration, /alter\s+table\s+public\.(sales|expenses|supplier_invoices|inventory_movements|payroll|daily_labor)/i);
  assert.doesNotMatch(migration, /insert\s+into\s+public\.(sales|expenses|supplier_invoices|inventory_movements|payroll|daily_labor)/i);
});
