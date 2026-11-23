import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const workspace = await readFile(new URL("../src/v22/projectWorkspace.jsx", import.meta.url), "utf8");

test("project expenses can be submitted through the protected operational actual-cost workflow", () => {
  assert.match(workspace, /ProjectExpensesTab rows=\{summary\.expenses\}/);
  assert.match(workspace, /supabase\.rpc\("prepare_operational_source_actual_cost"/);
  assert.match(workspace, /target_source_type:"approved_expense"/);
  assert.match(workspace, /target_source_id:row\.id/);
  assert.match(workspace, /row\.cost_posting_status==="not_posted" && !row\.cancelled_at/);
});

test("project expense submission remains pending approval and prevents duplicate submission", () => {
  assert.match(workspace, /قيد المراجعة/);
  assert.match(workspace, /إلا بعد اعتماد صاحب الصلاحية/);
  assert.match(workspace, /إعادة الإرسال بعد الربط ممنوعة لمنع التكرار/);
  assert.match(workspace, /row\.cost_posting_status==="not_posted"/);
});

test("project expense tab respects financial visibility and reports RPC errors", () => {
  assert.match(workspace, /canViewFinancials && <strong>\{money\(row\.amount\)\}/);
  assert.match(workspace, /<ErrorState error=\{error\}/);
  assert.match(workspace, /friendlyError\(result\.error\)/);
});
