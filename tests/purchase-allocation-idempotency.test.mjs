import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const sql = await readFile(new URL("../supabase/migrations/20261123200000_fix_purchase_allocation_idempotency_alias.sql", import.meta.url), "utf8");

test("purchase allocation idempotent replay uses a non-conflicting SQL alias", () => {
  assert.match(sql, /jsonb_array_elements\(target_allocations\) payload_line/i);
  assert.match(sql, /payload_line->'allocations'/i);
  assert.match(sql, /payload_line->>'purchase_order_item_id'/i);
  assert.doesNotMatch(sql, /jsonb_array_elements\(target_allocations\) item/i);
});
