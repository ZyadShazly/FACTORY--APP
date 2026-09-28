import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { ACTION_PERMISSIONS, actionPermissions } from "../src/app/actionPermissions.js";

const migration = fs.readFileSync(
  "supabase/migrations/20260928191257_accounting_coa_core.sql",
  "utf8",
);

test("minimal COA stops before bank and fixed-asset user subaccounts", () => {
  assert.match(migration, /'1','الأصول','Assets'/);
  assert.match(migration, /'1\.1','الأصول المتداولة','Current Assets'/);
  assert.match(migration, /'1\.1\.02','البنك','Bank'/);
  assert.match(migration, /'1\.2','الأصول الثابتة','Fixed Assets'/);
  assert.doesNotMatch(migration, /'1\.1\.02\.[0-9]+/);
  assert.doesNotMatch(migration, /'1\.2\.[0-9]+/);
});

test("COA RPCs support add, edit, hierarchy safety and owner group conversion", () => {
  assert.match(migration, /create or replace function public\.get_accounting_accounts\(\)/);
  assert.match(migration, /create or replace function public\.create_accounting_account\(payload jsonb\)/);
  assert.match(migration, /create or replace function public\.update_accounting_account\(target_id uuid,payload jsonb\)/);
  assert.match(migration, /create or replace function public\.owner_convert_account_to_group\(target_id uuid,reason text\)/);
  assert.match(migration, /Child account type must match its parent account type/);
  assert.match(migration, /Owner must convert it to a group account before adding subaccounts/);
  assert.match(migration, /Account with subaccounts must remain a group account/);
});

test("accounting stays disabled after COA bootstrap", () => {
  assert.match(migration, /values\(\s*true,\s*false,\s*null,/);
});

test("accounting RPCs are authenticated-only", () => {
  for (const fn of [
    "get_accounting_accounts\\(\\)",
    "create_accounting_account\\(jsonb\\)",
    "update_accounting_account\\(uuid,jsonb\\)",
    "owner_convert_account_to_group\\(uuid,text\\)",
  ]) {
    assert.match(migration, new RegExp(`revoke all on function public\\.${fn} from public,anon`));
    assert.match(migration, new RegExp(`grant execute on function public\\.${fn} to authenticated`));
  }
});

test("accounting permissions are part of the existing role matrix", () => {
  for (const key of [
    "accounting_view",
    "accounting_accounts_manage",
    "accounting_journal_create",
    "accounting_journal_post",
    "accounting_journal_reverse",
    "accounting_journal_edit_posted",
    "accounting_reports_view",
    "accounting_settings_manage",
    "accounting_period_manage",
  ]) {
    assert.ok(ACTION_PERMISSIONS.includes(key), key);
  }
});

test("accountant gets normal accounting operations but never master-only controls", () => {
  const p = actionPermissions({ role: "accountant", permissions: {} });
  assert.equal(p.accounting_view, true);
  assert.equal(p.accounting_accounts_manage, true);
  assert.equal(p.accounting_journal_create, true);
  assert.equal(p.accounting_journal_post, true);
  assert.equal(p.accounting_journal_reverse, true);
  assert.equal(p.accounting_reports_view, true);
  assert.equal(p.accounting_journal_edit_posted, false);
  assert.equal(p.accounting_settings_manage, false);
  assert.equal(p.accounting_period_manage, false);
});

test("manager accounting access is explicit and posted-edit stays owner-only", () => {
  const p = actionPermissions({
    role: "manager",
    permissions: {
      accounting_view: true,
      accounting_reports_view: true,
      accounting_journal_edit_posted: true,
    },
  });
  assert.equal(p.accounting_view, true);
  assert.equal(p.accounting_reports_view, true);
  assert.equal(p.accounting_journal_edit_posted, false);
  assert.equal(p.accounting_settings_manage, false);
  assert.equal(p.accounting_period_manage, false);
});

test("production never receives accounting controls", () => {
  const p = actionPermissions({
    role: "production",
    permissions: Object.fromEntries(ACTION_PERMISSIONS.map((key) => [key, true])),
  });
  for (const key of ACTION_PERMISSIONS.filter((key) => key.startsWith("accounting_"))) {
    assert.equal(p[key], false, key);
  }
});

test("owner remains the accounting master", () => {
  const p = actionPermissions({ role: "owner", permissions: {} });
  for (const key of ACTION_PERMISSIONS.filter((key) => key.startsWith("accounting_"))) {
    assert.equal(p[key], true, key);
  }
});
