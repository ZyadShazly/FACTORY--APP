import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const migrationUrl = new URL("../supabase/migrations/20260810180000_project_file_archive_lifecycle.sql", import.meta.url);
const uiUrl = new URL("../src/v22/projects.jsx", import.meta.url);

test("project files use an audited reversible archive and retain storage", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  assert.match(sql, /archived_at timestamptz/);
  assert.match(sql, /Project files cannot be deleted/);
  assert.match(sql, /archive_project_file/);
  assert.match(sql, /restore_project_file/);
  assert.match(sql, /storage_retained', true/);
  assert.match(sql, /drop policy if exists project_files_storage_delete/);
  assert.match(sql, /private\.project_can_view\(file_row\.project_id\)/);
  assert.match(sql, /private\.project_has_permission\('project_files_delete'\)/);
});

test("project file UI archives and restores without deleting metadata or storage", async () => {
  const source = await readFile(uiUrl, "utf8");
  assert.match(source, /restore_project_file":"archive_project_file/);
  assert.match(source, /أرشيف ملفات المشروع/);
  assert.match(source, /reasonRequired/);
  assert.doesNotMatch(source, /from\(PROJECT_FILES_TABLE\)\.delete\(\)/);
  assert.doesNotMatch(source, /storage\.from\(PROJECT_FILES_BUCKET\)\.remove/);
});
