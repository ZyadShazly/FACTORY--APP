import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const foundation = fs.readFileSync('supabase/migrations/202607210001_inventory_operations.sql','utf8');
const hardening = fs.readFileSync('supabase/migrations/202607210002_inventory_operations_hardening.sql','utf8');

test('inventory operations stay on the immutable ledger', () => {
  assert.match(foundation,/create or replace function public\.transfer_inventory/);
  assert.match(foundation,/create or replace function public\.adjust_inventory/);
  assert.match(foundation,/create table if not exists public\.inventory_count_sessions/);
  assert.match(foundation,/create table if not exists public\.inventory_count_lines/);
  assert.doesNotMatch(foundation,/update public\.inventory_movements\s+set/i);
  assert.doesNotMatch(foundation,/delete from public\.inventory_movements/i);
});

test('transfer is paired, reasoned, and balance protected', () => {
  assert.match(foundation,/Source and destination warehouses must differ/);
  assert.match(foundation,/Positive transfer quantity required/);
  assert.match(foundation,/Transfer reason required/);
  assert.match(foundation,/Insufficient inventory balance/);
  assert.match(foundation,/values\('transfer_out'/);
  assert.match(foundation,/values\('transfer_in'/);
  assert.match(foundation,/transfer_id/);
});

test('count posting rejects stale stock and requires a reason', () => {
  assert.match(hardening,/Inventory changed after count capture/);
  assert.match(hardening,/Posting reason required/);
  assert.match(hardening,/for update/);
  assert.match(hardening,/perform public\.adjust_inventory/);
});

test('direct table access is revoked and production events remain disabled', () => {
  assert.match(foundation,/revoke all on public\.inventory_count_sessions,public\.inventory_count_lines from anon,authenticated/);
  assert.match(hardening,/revoke all on function public\.record_production_inventory_event\([\s\S]*authenticated/);
  assert.doesNotMatch(hardening,/grant execute on function public\.record_production_inventory_event/);
});

test('all public inventory operation functions have fixed search paths', () => {
  for (const name of ['transfer_inventory','adjust_inventory','create_inventory_count_session','save_inventory_count_line','post_inventory_count_session']) {
    const pattern = new RegExp(`create or replace function public\\.${name}[\\s\\S]*?security definer set search_path=public,private,pg_temp`);
    assert.match(foundation + '\n' + hardening, pattern);
  }
});
