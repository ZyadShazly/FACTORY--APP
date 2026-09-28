import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const sql = fs.readFileSync(
  new URL("../supabase/migrations/20260928172634_pilot_internal_rpc_anon_acl.sql", import.meta.url),
  "utf8"
);

test("internal pilot RPCs are not executable by anon", () => {
  assert.match(sql, /revoke all on function public\.get_audit_log_visible\(\)[\s\S]*from public, anon;/i);
  assert.match(sql, /revoke all on function public\.owner_override_purchase_request_budget\(uuid,text\)[\s\S]*from public, anon;/i);
  assert.match(sql, /revoke all on function public\.owner_recover_asset_assignment_state\(uuid,text\)[\s\S]*from public, anon;/i);
});

test("authenticated app users retain execute access", () => {
  assert.match(sql, /grant execute on function public\.get_audit_log_visible\(\)[\s\S]*to authenticated;/i);
  assert.match(sql, /grant execute on function public\.owner_override_purchase_request_budget\(uuid,text\)[\s\S]*to authenticated;/i);
  assert.match(sql, /grant execute on function public\.owner_recover_asset_assignment_state\(uuid,text\)[\s\S]*to authenticated;/i);
});
