import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const foundation = await readFile(
  new URL("../supabase/migrations/202607190001_project_workspace_upgrade.sql", import.meta.url),
  "utf8",
);
const hardening = await readFile(
  new URL("../supabase/migrations/202607190002_project_workspace_performance_hardening.sql", import.meta.url),
  "utf8",
);

const expectedIndexes = [
  ["project_members_profile_idx", "project_members", "profile_id"],
  ["project_members_employee_idx", "project_members", "employee_id"],
  ["project_members_added_by_idx", "project_members", "added_by"],
  ["project_milestones_created_by_idx", "project_milestones", "created_by"],
  ["project_milestones_updated_by_idx", "project_milestones", "updated_by"],
  ["projects_created_by_idx", "projects", "created_by"],
  ["projects_progress_updated_by_idx", "projects", "progress_updated_by"],
  ["projects_lifecycle_changed_by_idx", "projects", "lifecycle_changed_by"],
  ["projects_updated_by_idx", "projects", "updated_by"],
];

test("every new project workspace foreign key has a partial covering index", () => {
  for (const [name, table, column] of expectedIndexes) {
    assert.match(
      hardening,
      new RegExp(
        `create index if not exists ${name}\\s+on public\\.${table}\\(${column}\\) where ${column} is not null;`,
        "i",
      ),
    );
  }
});

test("project workspace index names are unique across both migrations", () => {
  const indexNames = [...`${foundation}\n${hardening}`.matchAll(
    /create (?:unique )?index if not exists ([a-z0-9_]+)/gi,
  )].map((match) => match[1]);
  assert.equal(new Set(indexNames).size, indexNames.length);
  assert.equal(
    [...hardening.matchAll(/create index if not exists ([a-z0-9_]+)/gi)].length,
    expectedIndexes.length,
  );
});

test("project realtime signal policy caches stable identity helpers in init plans", () => {
  const policy = hardening.slice(hardening.indexOf("create policy project_realtime_signal_select"));
  assert.match(policy, /\(select private\.project_profile_active\(\)\)/);
  assert.match(policy, /\(select public\.current_identity_role\(\)\)/);
  assert.equal((policy.match(/\(select auth\.uid\(\)\)/g) || []).length, 2);
  assert.doesNotMatch(policy, /(?<!select )auth\.uid\(\)/);
  assert.doesNotMatch(policy, /(?<!select )private\.project_profile_active\(\)/);
  assert.doesNotMatch(policy, /(?<!select )public\.current_identity_role\(\)/);
});

test("hardening migration changes no unrelated legacy objects or project authorization code", () => {
  assert.doesNotMatch(hardening, /\b(profiles|expenses|employees|payroll|assets)_[a-z0-9_]*\b/i);
  assert.doesNotMatch(hardening, /create or replace function|alter table|create table|drop table/i);
  assert.doesNotMatch(hardening, /\b(insert|update|delete)\s+(?:into|public\.)/i);
  assert.equal((hardening.match(/drop policy if exists/gi) || []).length, 1);
  assert.equal((hardening.match(/create policy/gi) || []).length, 1);
  assert.match(hardening, /on public\.project_realtime_signal/);
});
