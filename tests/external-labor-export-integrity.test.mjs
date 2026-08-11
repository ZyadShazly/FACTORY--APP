import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const exportsSource = readFileSync("src/reporting/professionalExports.js", "utf8");

test("external labor export reconciles net settlement rather than gross wages", () => {
  assert.match(exportsSource, /label: "صافي المستحق", value: sum\(rows, "net_amount"\)/);
  assert.match(exportsSource, /sum\(rows, "net_amount"\) - sum\(rows, "paid_amount"\)/);
  for (const field of ["addition_amount", "addition_reason", "deduction_amount", "deduction_reason", "net_amount"]) {
    assert.match(exportsSource, new RegExp(`key: "${field}"`));
  }
  assert.match(exportsSource, /partially_paid: "مدفوع جزئيًا"/);
});
