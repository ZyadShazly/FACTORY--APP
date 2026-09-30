import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260930065236_accounting_source_repost_guard.sql",
  "utf8",
);

test("active duplicate source events remain idempotent",()=>{
  assert.match(sql,/if existing_link_status='active'[\s\S]*existing_journal_status='posted'[\s\S]*return existing_entry/);
});

test("reposting a reversed source identity is blocked explicitly",()=>{
  assert.match(sql,/existing_link_status='reversed'[\s\S]*existing_journal_status='reversed'/);
  assert.match(sql,/previously reversed and cannot be reposted with the same source identity/);
});

test("unexpected existing source states fail closed",()=>{
  assert.match(sql,/Existing accounting source link is not in a reusable posted state/);
});

test("source-post helper still uses advisory locking and balanced journal validation",()=>{
  assert.match(sql,/pg_advisory_xact_lock/);
  assert.match(sql,/accounting_assert_entry_balanced\(saved\.id\)/);
  assert.match(sql,/accounting_source_links/);
});

test("private source-post helper remains inaccessible to API roles",()=>{
  assert.match(sql,/revoke all on function private\.accounting_post_source_journal\([\s\S]*from public,anon,authenticated/);
});

test("guard migration does not touch operational data or backfill journals",()=>{
  assert.doesNotMatch(sql,/update\s+public\.(sales|expenses|payroll|daily_labor|rentals|assets|projects|supplier_invoices|customer_receipts)/i);
  assert.doesNotMatch(sql,/insert into public\.accounting_journal_entries[\s\S]*select[\s\S]*from public\./i);
});
