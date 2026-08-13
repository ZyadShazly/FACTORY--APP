import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const blockerSql = fs.readFileSync(new URL("../supabase/migrations/20260813063000_final_uat_release_blockers.sql", import.meta.url), "utf8");
const overrideSql = fs.readFileSync(new URL("../supabase/migrations/20260813090000_owner_override_and_budget_guard.sql", import.meta.url), "utf8");
const followupSql = fs.readFileSync(new URL("../supabase/migrations/20260813093000_operational_integrity_followups.sql", import.meta.url), "utf8");
const budgetGuardSql = fs.readFileSync(new URL("../supabase/migrations/20260813094500_budget_guard_unlinked_items.sql", import.meta.url), "utf8");
const bootstrap = fs.readFileSync(new URL("../src/app/dataBootstrap.js", import.meta.url), "utf8");
const procurement = fs.readFileSync(new URL("../src/operational/ProcurementWorkspace.jsx", import.meta.url), "utf8");

test("SEC-01 audit and assets fail closed at the backend", () => {
  assert.match(blockerSql, /Assets view permission required/);
  assert.match(blockerSql, /Audit log access requires owner or manager role/);
  assert.match(blockerSql, /revoke select on public\.audit_log from anon, authenticated/i);
  assert.match(bootstrap, /supabase\.rpc\("get_audit_log_visible"\)/);
  assert.doesNotMatch(bootstrap, /from\(table\)[\s\S]*legacy rows/);
});

test("FIN-01 and Daily Labor Actual Cost use explicit category and base currency", () => {
  assert.match(blockerSql, /e\.category[\s\S]*p_source_category/);
  assert.match(blockerSql, /p_category := case/);
  assert.match(followupSql, /alter column currency set default private\.current_base_currency\(\)/);
});

test("PAY-01 payroll snapshot selects the full row instead of casting a composite", () => {
  assert.match(blockerSql, /select p\.\* into payroll_row/);
  assert.doesNotMatch(blockerSql, /select p into payroll_row/);
});

test("PROC-01 supplier invoices bootstrap base total and support non-project stock orders", () => {
  assert.match(blockerSql, /0,'submitted'/);
  assert.match(blockerSql, /if po\.project_id is not null then/);
  assert.match(blockerSql, /base_total_amount=round\(x\.total_amount\*effective_rate,2\)/);
});

test("PROD-01 production receipt synchronizes the order costing fields", () => {
  assert.match(blockerSql, /production_receipt_sync_order_cost/);
  assert.match(blockerSql, /set materials_cost=material_cost/);
  assert.match(blockerSql, /total_cost=capitalized_total/);
});

test("PM-BUD-01 blocks ordinary over-budget approval but gives Owner an audited override", () => {
  assert.match(overrideSql, /Purchase request exceeds the approved project budget; Owner override is required/);
  assert.match(overrideSql, /Owner override reason is required/);
  assert.match(overrideSql, /purchase_request_budget_override/);
  assert.match(overrideSql, /owner_break_glass/);
  assert.match(budgetGuardSql, /project_total/);
  assert.match(budgetGuardSql, /single_budget_quantity/);
  assert.match(procurement, /تجاوز استثنائي للميزانية/);
  assert.match(procurement, /owner_override_purchase_request_budget/);
});

test("PM-BUD-02 rejection and asset settlement recovery preserve workflow history", () => {
  assert.match(overrideSql, /budget_rejected/);
  assert.match(overrideSql, /rejection_reason=btrim\(rejection_reason\)/);
  assert.match(followupSql, /asset_settlement_rejected/);
  assert.match(followupSql, /owner_recover_asset_assignment_state/);
});

test("receipt preview surfaces rejected quantity and inspection notes", () => {
  assert.match(procurement, /rejected_quantity/);
  assert.match(procurement, /inspection_notes/);
  assert.match(procurement, /المرفوض\/التالف/);
  assert.match(procurement, /ملاحظة الفحص/);
});
