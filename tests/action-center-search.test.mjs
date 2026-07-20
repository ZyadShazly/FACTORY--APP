import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration = fs.readFileSync('supabase/migrations/202607200008_action_center_search.sql','utf8');
const shell = fs.readFileSync('src/layout/AppShell.jsx','utf8');

test('action center and search are protected RPCs',()=>{
  assert.match(migration,/security definer/gi);
  assert.match(migration,/set search_path = public, private, pg_temp/gi);
  assert.match(migration,/revoke all on function public\.get_action_center\(integer\) from public, anon/i);
  assert.match(migration,/revoke all on function public\.search_workspace\(text, integer\) from public, anon/i);
  assert.match(migration,/grant execute on function public\.get_action_center\(integer\) to authenticated/i);
  assert.match(migration,/grant execute on function public\.search_workspace\(text, integer\) to authenticated/i);
});

test('production search is role-scoped and bounded',()=>{
  assert.match(migration,/role_name in \('owner','manager','accountant','production'\)/i);
  assert.match(migration,/least\(coalesce\(limit_count,20\),50\)/i);
  assert.match(migration,/length\(q\) < 2/i);
  assert.match(migration,/receiver_profile_id=actor or aa\.receiver_employee_id=actor_employee/i);
});

test('topbar uses live protected sources',()=>{
  assert.match(shell,/supabase\.rpc\("get_action_center"/i);
  assert.match(shell,/supabase\.rpc\("search_workspace"/i);
  assert.match(shell,/window\.setTimeout/i);
  assert.doesNotMatch(shell,/from\("projects"\)/i);
  assert.doesNotMatch(shell,/from\("employees"\)/i);
});
