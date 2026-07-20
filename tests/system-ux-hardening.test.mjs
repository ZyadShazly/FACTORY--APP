import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration = fs.readFileSync('supabase/migrations/202607190020_system_ux_hardening.sql','utf8');
const acl = fs.readFileSync('supabase/migrations/202607190021_system_ux_hardening_rpc_acl.sql','utf8');
const ux = fs.readFileSync('src/userExperience.js','utf8');
const patcher = fs.readFileSync('scripts/apply-system-ux-hardening-safe.mjs','utf8');

test('return token columns allow completed and emergency workflows',()=>{
  assert.match(migration,/asset_return_events[\s\S]*confirmation_token_hash drop not null/i);
  assert.match(migration,/confirmation_expires_at drop not null/i);
  assert.match(migration,/pending_without_link/);
  assert.match(migration,/already_confirmed/);
  assert.match(migration,/replaced/);
});

test('confirmation lifecycle is auditable and renewable',()=>{
  for(const token of ['confirmation_sent_at','confirmation_opened_at','confirmation_resend_count','confirmation_invalidated_at']) assert.match(migration,new RegExp(token));
  assert.match(migration,/renew_asset_confirmation_link/);
  assert.match(migration,/confirmation_resend_count=confirmation_resend_count\+1/);
  assert.match(acl,/renew_asset_confirmation_link/);
  assert.match(acl,/from public, anon/);
});

test('employee history uses inactivation instead of deletion',()=>{
  assert.match(migration,/deactivate_employee/);
  assert.match(migration,/update public\.employees set status='terminated'/);
  assert.match(patcher,/deactivate_employee/);
  assert.match(patcher,/employees:deactivate/);
});

test('currency and errors are centralized',()=>{
  assert.match(migration,/create table if not exists public\.system_settings/);
  assert.match(ux,/formatMoney/);
  assert.match(ux,/userFacingError/);
  assert.match(ux,/23503/);
});

test('projects and custody UI patches are included',()=>{
  assert.match(patcher,/project\.execution_stage \|\| project\.status/);
  assert.match(patcher,/confirmationStatusLabel/);
  assert.match(patcher,/إدارة حالة المشروع والإنجاز/);
  assert.match(patcher,/انتهت صلاحية الرابط/);
});
