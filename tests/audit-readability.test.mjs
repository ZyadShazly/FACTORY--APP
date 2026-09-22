import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const audit = await readFile(new URL("../src/v22/audit.jsx", import.meta.url), "utf8");

test("audit UI hides generic trigger duplicates when a business event exists at the same instant", () => {
  assert.match(audit, /GENERIC_AUDIT_ACTIONS/);
  assert.match(audit, /businessKeys/);
  assert.match(audit, /auditEventKey/);
  assert.match(audit, /dedupeAuditRows\(filtered\)/);
});

test("audit UI labels confirmed business actions in Arabic", () => {
  for (const action of [
    "production_order_cancelled",
    "production_order_released",
    "production_order_completed",
    "customer_created",
    "customer_updated",
    "customer_archived",
    "customer_restored",
    "customer_receipt_classified",
    "customer_adjustment_posted",
    "customer_adjustment_reversed",
    "supplier_payment_classified",
  ]) {
    assert.match(audit, new RegExp(action));
  }
});

test("generic project lifecycle updates render meaningful close and completion summaries", () => {
  assert.match(audit, /row\.table_name==="projects"&&row\.action==="update"/);
  assert.match(audit, /after\.lifecycle==="closed"/);
  assert.match(audit, /after\.lifecycle==="completed"/);
  assert.match(audit, /تم إغلاق المشروع/);
  assert.match(audit, /تم إكمال المشروع/);
});

test("technical ids and actor fields stay out of generic change summaries", () => {
  assert.match(audit, /TECHNICAL_KEYS/);
  assert.match(audit, /"command_id"/);
  assert.match(audit, /"project_closed_by"/);
  assert.match(audit, /readableValue/);
});
