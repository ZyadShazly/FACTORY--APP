import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration = fs.readFileSync(
  "supabase/migrations/20260803061517_assets_foreign_key_indexes.sql",
  "utf8",
);

const expectedIndexes = [
  ["asset_assignments", "confirmed_by_user_id"],
  ["asset_assignments", "created_by"],
  ["asset_assignments", "department_id"],
  ["asset_assignments", "issue_location_id"],
  ["asset_assignments", "issued_by"],
  ["asset_assignments", "override_actor_id"],
  ["asset_assignments", "updated_by"],
  ["asset_attachments", "return_event_id"],
  ["asset_attachments", "settlement_id"],
  ["asset_attachments", "uploaded_by"],
  ["asset_categories", "created_by"],
  ["asset_categories", "updated_by"],
  ["asset_identity_binding_migration_report", "receiver_employee_id"],
  ["asset_identity_binding_migration_report", "assignment_id"],
  ["asset_locations", "created_by"],
  ["asset_locations", "parent_id"],
  ["asset_locations", "project_id"],
  ["asset_locations", "updated_by"],
  ["asset_movements", "actor_id"],
  ["asset_movements", "from_location_id"],
  ["asset_movements", "settlement_id"],
  ["asset_movements", "to_location_id"],
  ["asset_return_events", "confirmed_by_user_id"],
  ["asset_return_events", "override_actor_id"],
  ["asset_return_events", "received_by"],
  ["asset_settings", "updated_by"],
  ["asset_settlements", "approved_by"],
  ["asset_settlements", "created_by"],
  ["asset_settlements", "rejected_by"],
  ["assets", "category_id"],
  ["assets", "created_by"],
  ["assets", "current_location_id"],
  ["assets", "supplier_id"],
  ["assets", "updated_by"],
];

test("every remaining Assets foreign key has an idempotent covering index", () => {
  for (const [table, column] of expectedIndexes) {
    assert.match(
      migration,
      new RegExp(`create index if not exists [a-z0-9_]+\\s+on public\\.${table}\\(${column}\\)`),
      `missing index for ${table}.${column}`,
    );
  }
  assert.equal((migration.match(/create index if not exists/g) || []).length, expectedIndexes.length);
});

test("nullable links use bounded partial indexes", () => {
  for (const column of [
    "confirmed_by_user_id", "department_id", "issue_location_id", "issued_by",
    "override_actor_id", "return_event_id", "settlement_id", "uploaded_by",
    "parent_id", "project_id", "actor_id", "from_location_id", "to_location_id",
    "approved_by", "rejected_by", "current_location_id", "supplier_id",
  ]) {
    assert.match(migration, new RegExp(`on public\\.[a-z_]+\\(${column}\\)\\s+where ${column} is not null`));
  }
});

test("index closeout is additive and does not rewrite Assets data", () => {
  assert.doesNotMatch(migration, /drop\s+(table|index)|truncate|delete\s+from|update\s+public|insert\s+into/i);
  assert.match(migration, /^-- Complete covering indexes[\s\S]*begin;[\s\S]*commit;\s*$/);
});
