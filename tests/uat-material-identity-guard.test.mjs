import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/202608040900_uat_material_identity_guard.sql', import.meta.url),
  'utf8',
);

test('UAT-010 normalizes case and whitespace before duplicate checks', () => {
  assert.match(migration, /create or replace function public\.normalize_material_identity/);
  assert.match(migration, /lower\(regexp_replace\(btrim\(value\), '\\\\s\+'/);
});

test('UAT-010 blocks new and renamed duplicate material identities', () => {
  assert.match(migration, /before insert or update of name on public\.materials/);
  assert.match(migration, /errcode = '23505'/);
  assert.match(migration, /same normalized name already exists/);
});

test('UAT-010 preserves legacy rows and exposes duplicate reconciliation evidence', () => {
  assert.match(migration, /create or replace view public\.material_duplicate_candidates/);
  assert.match(migration, /having count\(\*\) > 1/);
  assert.doesNotMatch(migration, /delete from public\.materials/i);
  assert.doesNotMatch(migration, /update public\.materials\s+set name/i);
});
