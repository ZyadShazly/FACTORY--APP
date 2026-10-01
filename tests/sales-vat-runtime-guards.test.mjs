import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const guard=fs.readFileSync(
  "supabase/migrations/20261001184820_fix_sales_vat_history_guard.sql",
  "utf8",
);
const constraint=fs.readFileSync(
  "supabase/migrations/20261001184909_fix_sales_vat_legacy_total_constraint.sql",
  "utf8",
);

test("sales history guard validates gross total and configurable tax",()=>{
  assert.match(guard,/new\.tax_rate<0[\s\S]*new\.tax_rate>100/);
  assert.match(guard,/expected_tax:=round\(expected_net\*new\.tax_rate\/100,2\)/);
  assert.match(guard,/expected_total:=round\(expected_net\+expected_tax,2\)/);
  assert.match(guard,/new\.tax_rate is distinct from old\.tax_rate/);
  assert.match(guard,/new\.tax_amount is distinct from old\.tax_amount/);
});

test("legacy sale total constraint is replaced with tax-aware gross check",()=>{
  assert.match(constraint,/drop constraint if exists sales_total_consistency_check/);
  assert.match(
    constraint,
    /round\(total,2\)=round\(\(qty\*unit_price\)\+coalesce\(tax_amount,0\),2\)/,
  );
  assert.match(constraint,/not valid/);
});
