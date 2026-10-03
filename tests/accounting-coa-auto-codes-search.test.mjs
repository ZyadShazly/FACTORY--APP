import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync(
  "supabase/migrations/20261003181516_accounting_coa_auto_codes.sql",
  "utf8",
);
const collisionGuard=fs.readFileSync(
  "supabase/migrations/20261003181750_accounting_coa_auto_code_collision_guard.sql",
  "utf8",
);
const ui=fs.readFileSync("src/accounting/AccountingWorkspace.jsx","utf8");

test("COA can allocate the next code automatically inside each parent",()=>{
  assert.match(migration,/create or replace function private\.accounting_next_account_code\(target_parent uuid default null\)/);
  assert.match(migration,/where a\.parent_id=target_parent/);
  assert.match(migration,/max_value:=last_segment::bigint/);
  assert.match(migration,/next_value:=max_value\+1/);
  assert.match(migration,/return parent_code\|\|'\.'\|\|lpad\(next_value::text,segment_width,'0'\)/);
});

test("automatic segments grow beyond two digits instead of stopping at 99",()=>{
  assert.match(migration,/segment_width:=greatest\(segment_width,length\(next_value::text\)\)/);
  assert.match(migration,/segment_width integer:=2/);
  assert.doesNotMatch(migration,/next_value\s*>\s*99|next_value\s*<=\s*99/);
});

test("server serializes automatic code allocation and keeps explicit legacy callers compatible",()=>{
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/requested_code text:=nullif/);
  assert.match(migration,/code_value:=coalesce\(requested_code,private\.accounting_next_account_code\(parent_value\)\)/);
  assert.match(migration,/'code_source',case when requested_code is null then 'automatic' else 'explicit' end/);
});

test("authenticated managers can preview the next generated code through a protected RPC",()=>{
  assert.match(migration,/create or replace function public\.get_next_accounting_account_code\(target_parent uuid default null\)/);
  assert.match(migration,/accounting_permission_allowed\('accounting_accounts_manage'\)/);
  assert.match(migration,/revoke all on function public\.get_next_accounting_account_code\(uuid\)[\s\S]*from public,anon/);
  assert.match(migration,/grant execute on function public\.get_next_accounting_account_code\(uuid\)[\s\S]*to authenticated/);
});

test("new account UI previews automatic code but does not submit it as authoritative input",()=>{
  assert.match(ui,/get_next_accounting_account_code/);
  assert.match(ui,/value=\{compactAccountCode\(editor\.account_code\)\}[\s\S]*readOnly/);
  assert.match(ui,/بعد 99 يكمل 100 ثم 101/);
  assert.match(ui,/\.\.\.\(editor\.mode === "edit" \? \{ account_code: editor\.account_code\.trim\(\) \} : \{\}\)/);
});

test("parent account selection uses live search instead of a long scrolling select",()=>{
  assert.match(ui,/placeholder="ابحث بكود أو اسم الحساب الأب\.\.\."/);
  assert.match(ui,/accountMatchesLookup\(row, normalizedParentQuery\)/);
  assert.match(ui,/\.slice\(0, 8\)/);
  assert.match(ui,/accounting-parent-results/);
  assert.doesNotMatch(
    ui.match(/function AccountEditor[\s\S]*?\n}\n\nexport function AccountingWorkspace/)?.[0] || "",
    /<select value=\{editor\.parent_id\}/,
  );
});

test("main chart search remains available for large trees",()=>{
  assert.match(ui,/placeholder="بحث بالكود أو اسم الحساب\.\.\."/);
  assert.match(ui,/buildVisibleRows\(accounts, expanded, query, accountType\)/);
});

test("automatic code preview skips a code already used elsewhere in the hierarchy",()=>{
  assert.match(collisionGuard,/candidate:=parent_code\|\|'\.'\|\|lpad\(next_value::text,segment_width,'0'\)/);
  assert.match(collisionGuard,/where lower\(btrim\(a\.account_code\)\)=lower\(candidate\)/);
  assert.match(collisionGuard,/next_value:=next_value\+1/);
  assert.match(collisionGuard,/loop[\s\S]*exit when not exists/);
});

test("COA displays compact codes without changing canonical stored codes",()=>{
  assert.match(ui,/compactAccountCode\(row\.account_code\)/);
  assert.match(ui,/compactAccountCode\(parent\.account_code\)/);
  assert.match(ui,/compactAccountCode\(savedAccount\?\.account_code\)/);
});
