import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const aclMigration = readFileSync(
  "supabase/migrations/202608020001_inventory_typed_rpc_acl.sql",
  "utf8",
);
const definitionMigration = readFileSync(
  "supabase/migrations/202607290003_explicit_inventory_item_type.sql",
  "utf8",
);

test("typed inventory creation is not executable by PUBLIC or anon", () => {
  assert.match(
    aclMigration,
    /revoke execute on function\s+public\.create_inventory_item_typed\(text,text,text,text,uuid,boolean\)\s+from public, anon;/s,
  );
  assert.match(
    aclMigration,
    /grant execute on function\s+public\.create_inventory_item_typed\(text,text,text,text,uuid,boolean\)\s+to authenticated;/s,
  );
});

test("typed inventory creation retains its server-side role authorization", () => {
  assert.match(
    definitionMigration,
    /if not private\.inventory_manage_allowed\(\) then/,
  );
  assert.match(
    definitionMigration,
    /errcode='42501',message='Owner or manager role required'/,
  );
});

test("inventory ACL hardening does not change public asset confirmation RPCs", () => {
  assert.doesNotMatch(
    aclMigration,
    /asset_confirmation_preview|asset_return_confirmation_preview|confirm_asset_assignment|confirm_asset_return/,
  );
});
