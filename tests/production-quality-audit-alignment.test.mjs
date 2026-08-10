import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration = fs.readFileSync(
  new URL("../supabase/migrations/202608103200_production_quality_output_receipt.sql", import.meta.url),
  "utf8",
);

test("production completion inventory and audit use the quality-accepted output", () => {
  assert.match(migration, /new\.quantity_delta:=accepted_output/i);
  assert.match(migration, /new\.unit_cost:=round\(total_output_cost\/accepted_output,4\)/i);
  assert.match(migration, /production_completion_audit_alignment/i);
  assert.match(migration, /'finished_goods_quantity',receipt\.quantity_delta/i);
  assert.match(migration, /'finished_goods_unit_cost',receipt\.unit_cost/i);
  assert.match(migration, /Canonical production receipt is required for completion audit/i);
});
