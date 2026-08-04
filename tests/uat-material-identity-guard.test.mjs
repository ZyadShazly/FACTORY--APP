import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/202608040900_uat_material_identity_guard.sql', import.meta.url),
  'utf8',
);
const ui = readFileSync(
  new URL('../src/operational/MaterialsCatalogWorkspace.jsx', import.meta.url),
  'utf8',
);

test('UAT-010 normalizes case and whitespace before duplicate checks', () => {
  assert.match(migration, /create or replace function public\.normalize_material_identity/);
  assert.match(migration, /lower\(regexp_replace\(btrim\(value\), '\\\\s\+'/);
});

test('UAT-010 blocks new and renamed duplicate material names', () => {
  assert.match(migration, /before insert or update of name, material_code on public\.materials/);
  assert.match(migration, /errcode = '23505'/);
  assert.match(migration, /same normalized name already exists/);
});

test('UAT-010 requires a normalized unique code for every new material', () => {
  assert.match(migration, /add column if not exists material_code text/);
  assert.match(migration, /Material code is required for new materials/);
  assert.match(migration, /create unique index if not exists materials_material_code_normalized_uidx/);
  assert.match(migration, /normalize_material_code\(material_code\)/);
});

test('UAT-010 UI captures material code and blocks obvious duplicate names and codes', () => {
  assert.match(ui, /const\[code,setCode\]=useState\(""\)/);
  assert.match(ui, /material_code:cleanCode/);
  assert.match(ui, /duplicateName/);
  assert.match(ui, /duplicateCode/);
  assert.match(ui, /كود المادة/);
});

test('UAT-010 preserves legacy rows and exposes reconciliation evidence', () => {
  assert.match(migration, /create or replace view public\.material_duplicate_candidates/);
  assert.match(migration, /create or replace view public\.material_identity_reconciliation/);
  assert.match(migration, /having count\(\*\) > 1/);
  assert.doesNotMatch(migration, /delete from public\.materials/i);
  assert.doesNotMatch(migration, /update public\.materials\s+set/i);
});
