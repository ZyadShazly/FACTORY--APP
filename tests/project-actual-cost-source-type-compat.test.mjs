import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const sql = await readFile(new URL("../supabase/migrations/20261123193000_align_project_actual_cost_source_types.sql", import.meta.url), "utf8");

test("project actual-cost source types remain extensible for new procurement allocations", () => {
  assert.match(sql, /drop constraint if exists project_actual_cost_entries_source_type_check/i);
});
