import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const sql=fs.readFileSync(
  "supabase/migrations/20261001120707_fix_accounting_deferred_balance_guard_security_context.sql",
  "utf8",
);

test("deferred balance guard retains trusted trigger execution context",()=>{
  assert.match(
    sql,
    /alter\s+function\s+private\.accounting_deferred_balance_guard\(\)\s+security\s+definer/i,
  );
});

test("deferred balance guard remains unavailable to API roles",()=>{
  assert.match(
    sql,
    /revoke\s+all\s+on\s+function\s+private\.accounting_deferred_balance_guard\(\)[\s\S]*?from\s+public,\s*anon,\s*authenticated/i,
  );
  assert.doesNotMatch(sql,/grant\s+execute[\s\S]*?authenticated/i);
});
