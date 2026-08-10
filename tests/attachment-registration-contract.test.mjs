import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/202608102600_attachment_registration_contract.sql", "utf8");
const projects = readFileSync("src/v22/projects.jsx", "utf8");
const assets = readFileSync("src/assets/AssetsPage.jsx", "utf8");

test("file metadata registration verifies object scope and permissions", () => {
  assert.match(migration, /register_project_file_upload/);
  assert.match(migration, /private\.project_has_permission\('project_files_upload'\)/);
  assert.match(migration, /storage\.objects where bucket_id='project-files' and name=file_path/);
  assert.match(migration, /register_asset_attachment/);
  assert.match(migration, /public\.has_permission\('assets_manage'\)/);
  assert.match(migration, /asset_attachments_bucket_path_uidx/);
  assert.match(migration, /revoke insert on table public\.project_files,public\.asset_attachments from anon,authenticated/);
});

test("failed registrations clean up only unregistered uploaded objects", () => {
  assert.match(migration, /discard_unregistered_upload/);
  assert.match(migration, /if exists\(select 1 from public\.project_files/);
  assert.match(migration, /if exists\(select 1 from public\.asset_attachments/);
  assert.match(projects, /supabase\.rpc\("register_project_file_upload"/);
  assert.match(projects, /supabase\.rpc\("discard_unregistered_upload"/);
  assert.match(assets, /rpc\("register_asset_attachment"/);
  assert.match(assets, /supabase\.rpc\("discard_unregistered_upload"/);
  assert.doesNotMatch(projects, /\.from\(PROJECT_FILES_TABLE\)\.insert/);
  assert.doesNotMatch(assets, /\.from\("asset_attachments"\)\.insert/);
});
