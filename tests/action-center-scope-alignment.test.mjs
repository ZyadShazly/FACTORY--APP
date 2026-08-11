import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync("supabase/migrations/20260810360000_action_center_scope_alignment.sql","utf8");

test("Production notifications and search only expose assigned orders",()=>{
  const assigned=/assigned_employee_id=actor_employee/g;
  assert.equal((migration.match(assigned)||[]).length>=2,true);
  assert.match(migration,/private\.project_can_view\(project\.id\)/);
  assert.match(migration,/not public\.is_current_profile_active\(\)/);
});

test("supplier notifications follow the current account balance",()=>{
  assert.match(migration,/'supplier_balance_due'/);
  assert.match(migration,/private\.supplier_due\(supplier\.id\)>0/);
  assert.doesNotMatch(migration,/'supplier_invoice_due'/);
});

test("search and action center remain protected RPCs",()=>{
  assert.match(migration,/revoke all on function public\.get_action_center\(integer\),public\.search_workspace\(text,integer\) from public,anon/);
  assert.match(migration,/grant execute on function public\.get_action_center\(integer\),public\.search_workspace\(text,integer\) to authenticated/);
});
