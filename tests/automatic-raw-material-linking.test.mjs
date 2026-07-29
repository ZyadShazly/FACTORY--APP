import test from"node:test";
import assert from"node:assert/strict";
import{readFileSync}from"node:fs";

const migration=readFileSync("supabase/migrations/202607290002_automatic_raw_material_linking.sql","utf8");

test("raw material linking is automatic idempotent and ambiguity-safe",()=>{
  assert.match(migration,/ensure_raw_material_inventory_item/);
  assert.match(migration,/where material_id=target_material/);
  assert.match(migration,/after insert or update of name,unit,active on public\.materials/);
  assert.match(migration,/for material_row in select id from public\.materials/);
  assert.match(migration,/product_id is null/);
  assert.match(migration,/candidate_count=1/);
  assert.match(migration,/ambiguous_name/);
  assert.match(migration,/'RM-'\|\|replace\(target_material::text,'-',''\)/);
  assert.match(migration,/pg_advisory_xact_lock/);
});

test("raw material reconciliation preserves history and existing links",()=>{
  assert.doesNotMatch(migration,/delete from public\.inventory_items/);
  assert.doesNotMatch(migration,/delete from public\.inventory_movements/);
  assert.match(migration,/if linked_item is not null then/);
  assert.match(migration,/return linked_item/);
});