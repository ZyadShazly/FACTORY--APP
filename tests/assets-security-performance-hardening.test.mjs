import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const migration = await readFile(
  new URL("../supabase/migrations/202607180008_assets_security_performance_hardening.sql", import.meta.url),
  "utf8",
);

const internalFunctions = [
  "asset_refresh_availability\\(public\\.assets\\)",
  "apply_asset_movement_balance\\(\\)",
  "protect_asset_integrity\\(\\)",
  "immutable_asset_ledger\\(\\)",
  "protect_assignment_state\\(\\)",
  "mask_asset_receiver_name\\(text\\)",
  "mask_asset_phone\\(text\\)",
  "protect_asset_confirmation_audit\\(\\)",
  "apply_asset_assignment_confirmation_internal\\(uuid, text, uuid\\)",
  "apply_asset_return_confirmation_internal\\(uuid, text, uuid, text\\)",
  "emit_asset_realtime_signal\\(\\)",
  "validate_asset_assignment_identity_binding\\(\\)",
  "protect_profile_employee_identity_link\\(\\)",
];

test("all Assets trigger-only and internal helpers are closed to API roles", () => {
  for (const signature of internalFunctions) {
    assert.match(
      migration,
      new RegExp(`revoke execute on function public\\.${signature}\\s+from public, anon, authenticated;`, "i"),
      `missing API-role EXECUTE revocation for ${signature}`,
    );
  }

  assert.match(migration, /has_function_privilege\('anon', function_oid, 'EXECUTE'\)/);
  assert.match(migration, /has_function_privilege\('authenticated', function_oid, 'EXECUTE'\)/);
});

test("every hardened internal function has a fixed search_path", () => {
  for (const signature of internalFunctions) {
    assert.match(
      migration,
      new RegExp(`alter function public\\.${signature}\\s+set search_path = public, pg_temp;`, "i"),
      `missing fixed search_path for ${signature}`,
    );
  }
});

test("frequent Assets foreign-key joins have idempotent indexes", () => {
  const expected = [
    ["asset_assignments", "receiver_employee_id"],
    ["asset_assignments", "receiver_profile_id"],
    ["asset_assignments", "project_id"],
    ["asset_return_events", "assignment_id"],
    ["asset_return_items", "assignment_item_id"],
    ["asset_settlements", "assignment_item_id"],
    ["asset_movements", "asset_id"],
    ["asset_movements", "assignment_id"],
    ["asset_movements", "return_event_id"],
    ["asset_attachments", "asset_id"],
    ["asset_attachments", "assignment_id"],
  ];

  for (const [table, column] of expected) {
    assert.match(
      migration,
      new RegExp(`create index if not exists idx_${table}_${column}\\s+on public\\.${table}\\(${column}\\);`, "i"),
      `missing index for ${table}.${column}`,
    );
  }
});

test("intentional public APIs and Advisor exceptions remain documented and untouched", () => {
  assert.doesNotMatch(migration, /revoke execute on function public\.asset_confirmation_preview/i);
  assert.doesNotMatch(migration, /revoke execute on function public\.asset_return_confirmation_preview/i);
  assert.doesNotMatch(migration, /revoke execute on function public\.confirm_asset_assignment\(uuid, text\)/i);
  assert.doesNotMatch(migration, /revoke execute on function public\.confirm_asset_return\(uuid, text\)/i);
  assert.match(migration, /public\.assets keeps RLS enabled with no direct policies/i);
  assert.match(migration, /public\.asset_alerts remains an owner-executed security-barrier view/i);
  assert.match(migration, /External bearer-link preview\/confirmation RPCs remain executable by anon/i);
});
