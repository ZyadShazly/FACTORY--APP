import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  "supabase/migrations/202608020002_project_approval_history_reconciliation.sql",
  "utf8",
);
const workspace = readFileSync("src/v22/projectWorkspace.jsx", "utf8");

test("active project without approval evidence is surfaced for reconciliation", () => {
  assert.match(
    migration,
    /p\.lifecycle in \('active','on_hold','completed','closed'\)[\s\S]*p\.project_approved_at is null[\s\S]*reconcile_project_approval_history/,
  );
  assert.match(migration, /'approval_reconciliation',jsonb_build_object/);
  assert.match(migration, /'key','project_approval_history'/);
  assert.match(migration, /'blocking',true/);
});

test("project approval step depends on recorded evidence, not lifecycle inference", () => {
  const approvalStart = migration.indexOf("'key','project_approved'");
  const approvalEnd = migration.indexOf("'key','manager_assigned'", approvalStart);
  const approvalStep = migration.slice(approvalStart, approvalEnd);
  assert.ok(approvalStart >= 0 && approvalEnd > approvalStart);
  assert.ok(approvalStep.includes("'complete',p.project_approved_at is not null"));
  assert.ok(!approvalStep.includes("'complete',p.lifecycle in"));
});

test("reconciliation does not fabricate or rewrite project history", () => {
  assert.doesNotMatch(
    migration,
    /update\s+public\.projects|insert\s+into\s+public\.project_activities|project_approved_at\s*=\s*(now\(\)|execution_started_at)/i,
  );
  assert.doesNotMatch(migration, /delete\s+from|truncate|drop\s+table/i);
});

test("workflow UI explains the safe reconciliation path", () => {
  assert.match(
    workspace,
    /reconcile_project_approval_history:"مراجعة سجل اعتماد المشروع"/,
  );
  assert.match(
    workspace,
    /workflow\?\.next_action === "reconcile_project_approval_history"[\s\S]*workflow\.approval_reconciliation/,
  );
});

test("workflow RPC remains authenticated-only", () => {
  assert.match(
    migration,
    /revoke all on function public\.get_project_pilot_workflow\(uuid\)[\s\S]*from public,anon,authenticated/,
  );
  assert.match(
    migration,
    /grant execute on function public\.get_project_pilot_workflow\(uuid\)[\s\S]*to authenticated/,
  );
});
