import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/20260810220000_expense_posting_integrity.sql", "utf8");
const ui = readFileSync("src/AppMonolith.jsx", "utf8");

test("new expenses use one protected idempotent posting workflow", () => {
  assert.match(migration, /create or replace function public\.post_expense\(/);
  assert.match(migration, /private\.commercial_page_allowed\('expenses'\)/);
  assert.match(migration, /expenses_command_uidx/);
  assert.match(migration, /where expenses\.command_id=post_expense\.command_id/);
  assert.match(migration, /grant execute on function public\.post_expense[\s\S]*to authenticated/);
  assert.match(migration, /revoke insert,update,delete on table public\.expenses from anon,authenticated/);
});

test("expense posting validates project state and records audit evidence", () => {
  assert.match(migration, /lifecycle not in \('closed','cancelled'\)/);
  assert.match(migration, /expense_amount is null or expense_amount<=0/);
  assert.match(migration, /'expenses',saved\.id::text,'expense_posted'/);
  assert.doesNotMatch(migration, /update public\.expenses set amount/i);
  assert.doesNotMatch(migration, /delete from public\.expenses/i);
});

test("expense UI retries with the same command and has no direct insert", () => {
  assert.match(ui, /supabase\.rpc\("post_expense"/);
  assert.match(ui, /scope: "expenses:post"/);
  assert.match(ui, /\.from\("expenses"\)\.select\("id,cancelled_at"\)\.eq\("command_id", commandId\)/);
  assert.doesNotMatch(ui, /insertRow\("expenses"/);
});
