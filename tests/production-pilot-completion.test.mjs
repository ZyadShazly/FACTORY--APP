import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync("supabase/migrations/202607280001_production_pilot_completion.sql","utf8");
const employeeMigration=fs.readFileSync("supabase/migrations/20260721100000_employee_management_workflow.sql","utf8");
const ui=fs.readFileSync("src/operational/ProductionWorkspace.jsx","utf8");
const css=fs.readFileSync("src/operational/productionWorkspace.css","utf8");

test("production execution reconciliation is additive and replay-safe",()=>{
  assert.match(migration,/add column if not exists assigned_employee_id/);
  assert.match(migration,/create table if not exists public\.production_operation_events/);
  assert.match(migration,/select 1 from pg_constraint[\s\S]*production_operation_quantities_check/);
  assert.match(migration,/select 1 from pg_constraint[\s\S]*production_operation_quality_status_check/);
  assert.doesNotMatch(migration,/\bdrop table\b|\btruncate\b/i);
});

test("fresh migration order safely tolerates assignment columns not existing yet",()=>{
  assert.match(employeeMigration,/information_schema\.columns/);
  assert.match(employeeMigration,/column_name='assigned_employee_id'/);
  assert.match(employeeMigration,/execute[\s\S]*assigned_employee_id/);
  assert.match(employeeMigration,/production_count\s*:=\s*0/);
});

test("every new foreign key has one named covering index",()=>{
  const expected=[
    ["assigned_employee_id","production_operations_assigned_employee_idx"],
    ["assigned_by","production_operations_assigned_by_idx"],
    ["operation_id","production_operation_events_operation_idx"],
    ["actor_id","production_operation_events_actor_idx"],
  ];
  for(const[column,name]of expected){
    assert.match(migration,new RegExp(`create index if not exists ${name}[^;]*\\(${column}(?:,|\\))`,"i"));
    assert.equal((migration.match(new RegExp(`create index if not exists ${name}`,"gi"))||[]).length,1);
  }
  const names=[...migration.matchAll(/create index if not exists\s+([a-z0-9_]+)/gi)].map(match=>match[1]);
  assert.equal(new Set(names).size,names.length);
});

test("operation events are immutable, RLS protected, and not directly writable",()=>{
  assert.match(migration,/alter table public\.production_operation_events enable row level security/);
  assert.match(migration,/revoke all on public\.production_operation_events from public,anon,authenticated/);
  assert.match(migration,/before update or delete on public\.production_operation_events/);
  assert.match(migration,/Production operation history is immutable/);
  assert.match(migration,/set search_path=''/g);
});

test("operation execution is assignment scoped and manager exceptions are audited",()=>{
  assert.match(migration,/private\.can_operate_assigned_operation\(target_operation\)/);
  assert.match(migration,/o\.assigned_employee_id=p\.employee_id/);
  assert.match(migration,/where e\.id=target_employee and e\.status='active'/);
  assert.match(migration,/public\.current_identity_role\(\) not in \('owner','manager'\)[\s\S]*Skip reason required/);
  assert.match(migration,/production_operation_skipped/);
});

test("completion requires materials, operations, and approved quality",()=>{
  assert.match(migration,/issued_quantity<required_quantity/);
  assert.match(migration,/status not in \('completed','skipped'\)/);
  assert.match(migration,/status='completed'[\s\S]*quality_status<>'approved'/);
  assert.match(migration,/All completed operations require approved quality review/);
});

test("cancellation preserves history and reverses every eligible material batch",()=>{
  assert.match(migration,/from public\.production_material_issues i/);
  assert.match(migration,/union all[\s\S]*production_material_requirements/);
  assert.match(migration,/perform public\.reverse_inventory_movement\(movement_id,reason\)/);
  assert.match(migration,/set status='cancelled'/);
  assert.match(migration,/production_order_cancelled/);
  assert.doesNotMatch(migration,/\bdelete from\b/i);
});

test("workspace scopes workers and redacts production costing by role",()=>{
  assert.match(migration,/where role_name<>'production' or o\.assigned_employee_id=actor_employee/);
  assert.match(migration,/role_name in \('owner','manager','accountant'\)/);
  assert.match(migration,/sum\(abs\(m\.quantity_delta\)\*m\.unit_cost\)/);
  assert.match(migration,/rev\.reversed_movement_id=m\.id/);
  assert.match(migration,/'view_financials',can_finance/);
});

test("production UX keeps active work compact and history on demand",()=>{
  assert.equal((ui.match(/<KpiCard\b/g)||[]).length,4);
  assert.match(ui,/PrimaryActionBar/);
  assert.match(ui,/ACTIVE_ORDER/);
  assert.match(ui,/ArchiveSection title="سجل الأوامر المكتملة والملغاة"/);
  assert.match(ui,/orderReference\(order\)/);
  assert.match(ui,/Progress label="الخامات"/);
  assert.match(ui,/Progress label="التشغيل"/);
  assert.match(ui,/الخطوة التالية/);
  assert.match(ui,/DetailsDrawer open=\{Boolean\(selected\)&&!finishing\}/);
});

test("production UX exposes controlled execution, quality, and cancellation actions",()=>{
  for(const rpc of[
    "assign_production_operation",
    "record_production_operation_event",
    "review_production_operation_quality",
    "complete_production_order",
    "cancel_production_order",
  ])assert.match(ui,new RegExp(`"${rpc}"`));
  assert.match(ui,/target_event:"complete"/);
  assert.match(ui,/good_quantity:accepted/);
  assert.match(ui,/bad_quantity:rejected/);
  assert.match(ui,/rework_qty:rework/);
  assert.match(ui,/إلغاء وعكس/);
  assert.doesNotMatch(ui,/supabase\.from\(/);
});

test("production layout contains wide and mobile viewports",()=>{
  assert.match(css,/grid-template-columns:minmax\(0,1fr\)/);
  assert.match(css,/max-width:100%/);
  assert.match(css,/@media\(max-width:700px\)/);
  assert.match(css,/\.production-order-card\{grid-template-columns:minmax\(0,1fr\)/);
});
