import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const migrationUrl = new URL(
  "../supabase/migrations/202607210003_fix_asset_cancel_record_alias.sql",
  import.meta.url,
);

const functionBody = (sql, name) =>
  sql.match(
    new RegExp(
      `create or replace function public\\.${name}\\([^]*?end\\n\\$\\$;`,
      "i",
    ),
  )?.[0] ?? "";

test("asset cancellation and reversal avoid unassigned record alias collisions", async () => {
  const sql = await readFile(migrationUrl, "utf8");

  for (const name of [
    "cancel_pending_asset_assignment",
    "reverse_asset_assignment",
  ]) {
    const fn = functionBody(sql, name);
    assert.notEqual(fn, "");
    assert.match(fn, /assignment_item_row public\.asset_assignment_items%rowtype/);
    assert.match(fn, /join public\.asset_assignment_items settlement_item/);
    assert.match(fn, /for assignment_item_row in/);
    assert.doesNotMatch(fn, /\bitem record\b/);
    assert.doesNotMatch(fn, /join public\.asset_assignment_items item\b/);
  }
});

test("asset cancellation is state-strict and cannot return stock twice", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  const cancel = functionBody(sql, "cancel_pending_asset_assignment");

  assert.match(cancel, /status<>'pending_receiver_confirmation'/);
  assert.match(cancel, /Pending assignment has no active items to reverse/);
  assert.match(cancel, /where id=assignment_item_row\.id/);
  assert.match(cancel, /set is_active=false/);
  assert.match(cancel, /movement_type,quantity,available_delta,assigned_delta/);
  assert.match(cancel, /'reversed',assignment_item_row\.quantity/);
  assert.match(cancel, /for update/);
});
