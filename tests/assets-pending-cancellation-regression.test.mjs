import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const migrationUrl = new URL(
  "../supabase/migrations/202607210004_fix_pending_asset_cancellation.sql",
  import.meta.url,
);

test("pending assignment cancellation avoids unassigned record shadowing", async () => {
  const sql = await readFile(migrationUrl, "utf8");

  assert.match(sql, /assignment_item public\.asset_assignment_items%rowtype/);
  assert.match(sql, /join public\.asset_assignment_items linked_item/);
  assert.doesNotMatch(sql, /join public\.asset_assignment_items item\s+on item\.id=settlement\.assignment_item_id/i);
  assert.match(sql, /active_item_count=0/);
  assert.match(sql, /for assignment_item in[\s\S]*for update/);
  assert.match(sql, /movement_type,quantity,available_delta,assigned_delta/);
  assert.match(sql, /'reversed',assignment_item\.quantity/);
  assert.match(sql, /set is_active=false/);
  assert.match(sql, /affected_items/);
});

test("pending assignment cancellation remains owner-only and auditable", async () => {
  const sql = await readFile(migrationUrl, "utf8");

  assert.match(sql, /actor uuid := auth\.uid\(\)/);
  assert.match(sql, /role='owner' and status='active'/);
  assert.match(sql, /btrim\(coalesce\(reason,''\)\)=''/);
  assert.match(sql, /insert into public\.audit_log/);
  assert.match(sql, /revoke all on function public\.cancel_pending_asset_assignment\(uuid,text\) from public, anon/);
  assert.match(sql, /grant execute on function public\.cancel_pending_asset_assignment\(uuid,text\) to authenticated/);
});
