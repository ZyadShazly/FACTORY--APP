import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync("supabase/migrations/20260803073000_product_lifecycle.sql","utf8");
const ui=fs.readFileSync("src/AppMonolith.jsx","utf8");
const production=fs.readFileSync("src/operational/ProductionWorkspace.jsx","utf8");

test("product history is archived instead of deleted or cascaded",()=>{
  assert.match(migration,/Product history cannot be deleted; archive it instead/);
  assert.match(migration,/production_orders_product_id_fkey[\s\S]*on delete restrict/);
  assert.match(migration,/finished_goods_link_reviews_product_id_fkey[\s\S]*on delete restrict/);
  assert.match(migration,/drop policy if exists products_delete_permission/);
  assert.match(migration,/revoke delete on table public\.products from anon,authenticated/);
});

test("product archive is authorized reversible and server stamped",()=>{
  assert.match(migration,/if not public\.can_delete_rows\(\)/);
  assert.match(migration,/Archive reason is required/);
  assert.match(migration,/new\.archived_at:=statement_timestamp\(\)/);
  assert.match(migration,/new\.archived_by:=auth\.uid\(\)/);
  assert.match(migration,/else\s+new\.archived_by:=null/);
});

test("archived products cannot enter new commercial or production work",()=>{
  assert.equal((migration.match(/create trigger require_active_product/g)||[]).length,3);
  assert.match(ui,/const activeProducts = data\.products\.filter\(\(product\) => !product\.archived_at\)/);
  assert.match(ui,/ArchiveSection title="المنتجات المؤرشفة"/);
  assert.match(ui,/archived_at: new Date\(\)\.toISOString\(\)/);
  assert.doesNotMatch(ui,/deleteRow\("products"/);
  assert.match(production,/data\.products\|\|\[\]\)\.filter\(row=>!row\.archived_at\)/);
});
