import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20260930100959_accounting_private_helper_acl.sql",
  "utf8",
);

const helpers=[
  "accounting_assert_entry_balanced\\(uuid\\)",
  "accounting_deferred_balance_guard\\(\\)",
  "accounting_guard_account_hierarchy\\(\\)",
  "accounting_guard_account_state\\(\\)",
  "accounting_guard_period_overlap\\(\\)",
  "accounting_guard_posting_account\\(\\)",
];

test("internal accounting helpers revoke direct API execution",()=>{
  for(const helper of helpers){
    assert.match(
      sql,
      new RegExp(`revoke all on function private\\.${helper}[\\s\\S]*?from public, anon, authenticated`,"i"),
    );
  }
});

test("ACL hardening is schema/data safe",()=>{
  assert.doesNotMatch(sql,/\b(create|alter|drop)\s+table\b/i);
  assert.doesNotMatch(sql,/\b(insert|update|delete|truncate)\b/i);
  assert.doesNotMatch(sql,/\bcreate\s+trigger\b/i);
  assert.doesNotMatch(sql,/\bcreate\s+or\s+replace\s+function\b/i);
});
