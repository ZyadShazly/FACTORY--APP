import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync("supabase/migrations/202607280002_project_pilot_completion.sql","utf8");
const workspace=fs.readFileSync("src/v22/projectWorkspace.jsx","utf8");
const projects=fs.readFileSync("src/v22/projects.jsx","utf8");
const errors=fs.readFileSync("src/operational/ui.jsx","utf8");
const css=fs.readFileSync("src/v22/projectWorkspace.css","utf8");

test("project pilot migration is additive and preserves existing history and data",()=>{
  assert.match(migration,/add column if not exists project_approved_by/);
  assert.match(migration,/add column if not exists project_closed_at/);
  assert.doesNotMatch(migration,/\bdrop table\b|\btruncate\b|\bdelete from\b/i);
  assert.doesNotMatch(migration,/\bupdate public\.projects\b[\s\S]*\bwhere\b[\s\S]*legacy_activation_exempt\s*=/i);
  assert.doesNotMatch(migration,/\binsert into public\.projects\b/i);
});

test("every new project workflow foreign key has a covering index with a unique name",()=>{
  const expected=[
    ["project_approved_by","projects_project_approved_by_idx"],
    ["execution_started_by","projects_execution_started_by_idx"],
    ["project_completed_by","projects_project_completed_by_idx"],
    ["project_closed_by","projects_project_closed_by_idx"],
  ];
  for(const[column,name]of expected){
    assert.match(migration,new RegExp(`create index if not exists ${name}\\s+on public\\.projects\\(${column}\\)\\s+where ${column} is not null`,"i"));
    assert.equal((migration.match(new RegExp(`create index if not exists ${name}`,"gi"))||[]).length,1);
  }
  const names=[...migration.matchAll(/create (?:unique )?index if not exists\s+([a-z0-9_]+)/gi)].map(match=>match[1]);
  assert.equal(new Set(names).size,names.length);
});

test("project approval requires valid details and an approved positive budget",()=>{
  assert.match(migration,/project_approval_readiness/);
  assert.match(migration,/status='approved'/);
  assert.match(migration,/approved\.expected_total_cost>0/);
  assert.match(migration,/total_with_waste>0/);
  assert.match(migration,/p\.lifecycle='planning' and next_lifecycle='ready_for_activation'/);
  assert.match(migration,/Project approval readiness checks are incomplete/);
  assert.match(migration,/p\.legacy_activation_exempt or override_ready/);
});

test("execution cannot begin before project approval and manager readiness",()=>{
  assert.match(migration,/p\.lifecycle='ready_for_activation' and next_lifecycle='active'/);
  assert.match(migration,/public\.project_activation_readiness\(target_project\)/);
  assert.match(migration,/Project execution readiness checks are incomplete/);
  assert.match(migration,/next_stage in \([\s\S]*'manufacturing'[\s\S]*\) and p\.lifecycle not in \('active','completed'\)/);
  assert.match(migration,/Project execution approval required/);
});

test("manager selection is active, conflict safe, and audited with old/new/reason",()=>{
  assert.match(migration,/where id=target_profile and coalesce\(status,'active'\)='active'/);
  assert.match(migration,/profile_id=target_profile/);
  assert.match(migration,/employee_id=selected_profile\.employee_id/);
  assert.match(migration,/Project manager change reason required/);
  assert.match(migration,/'previous_profile_id',previous_manager/);
  assert.match(migration,/'new_profile_id',target_profile/);
  assert.match(migration,/'reason',nullif\(btrim\(change_reason\),''\)/);
  assert.match(migration,/protect_project_manager_assignment/);
  assert.match(migration,/current_setting\('app\.project_manager_rpc',true\)/);
  assert.match(migration,/set_config\('app\.project_manager_rpc','on',true\)/);
  assert.match(workspace,/filter\(\(\[key\]\)=>key!=="project_manager"\)/);
});

test("completion returns exact blocking records and safe alternatives",()=>{
  for(const table of["project_milestones","purchase_requests","purchase_orders","supplier_invoices","production_orders","asset_assignments"]){
    assert.match(migration,new RegExp(`from public\\.${table}`));
  }
  assert.match(migration,/'first_record',first_/);
  assert.match(migration,/'safe_alternative'/);
  assert.match(migration,/Project completion dependencies remain open/);
  assert.match(migration,/Project closure dependencies remain open/);
  assert.doesNotMatch(migration,/public\.asset_items|asset_item_id|return_pending_confirmation/);
});

test("project-linked procurement and production are active-only with safe cancellation paths",()=>{
  for(const table of[
    "purchase_requests","supplier_quotes","purchase_orders","goods_receipts",
    "supplier_invoices","production_orders",
    "production_material_requirements","production_order_operations",
  ]) assert.match(migration,new RegExp(`'${table}'`));
  assert.match(migration,/if p\.lifecycle<>'active'/);
  assert.match(migration,/target_status in \([\s\S]*'cancelled','rejected','reversed','paid','closed'/);
  assert.match(migration,/if target_project is null then return/);
  assert.match(migration,/Project downstream workflow blocked\|/);
  assert.match(migration,/tg_table_name='supplier_invoices'[\s\S]*purchase_order_id/);
});

test("new definer functions use fixed search paths and helpers stay private",()=>{
  assert.ok((migration.match(/create or replace function/gi)||[]).length>=10);
  for(const name of[
    "project_approval_readiness","project_completion_readiness",
    "assert_project_downstream_allowed","guard_downstream_project_state",
  ]) assert.match(migration,new RegExp(`revoke all on function private\\.${name}`));
  assert.doesNotMatch(migration,/security definer\s+set search_path\s*=\s*public/i);
  assert.match(migration,/set search_path=''/);
});

test("project UI exposes one clear workflow, five or fewer KPIs, and archived history",()=>{
  assert.match(workspace,/get_project_pilot_workflow/);
  assert.match(workspace,/مسار اعتماد وتنفيذ المشروع/);
  assert.match(workspace,/الخطوة التالية/);
  assert.match(workspace,/project-workflow-steps/);
  assert.match(workspace,/assign_project_manager_secure/);
  assert.match(workspace,/approve_project_for_execution/);
  assert.match(workspace,/start_project_execution/);
  assert.match(workspace,/complete_project_execution/);
  assert.match(workspace,/close_project_secure/);
  assert.equal((workspace.match(/<StatCard\b/g)||[]).length,5);
  assert.equal((projects.match(/<KpiCard\b/g)||[]).length,4);
  assert.match(projects,/activeProjects/);
  assert.match(projects,/archivedProjects/);
  assert.match(projects,/ArchiveSection title="المشاريع المغلقة والملغاة"/);
});

test("structured blockers become friendly Arabic errors with exact project context",()=>{
  assert.match(errors,/Project downstream workflow blocked\|/);
  assert.match(errors,/code\|\|id/);
  assert.match(errors,/name\|\|"بدون اسم"/);
  assert.match(errors,/افتح مساحة المشروع/);
  assert.match(errors,/Project manager change reason required/);
  assert.match(errors,/Use the protected project manager assignment workflow/);
});

test("workflow layout is RTL responsive without a second wide summary",()=>{
  assert.match(workspace,/dir="rtl"/);
  assert.match(css,/project-workflow-steps/);
  assert.match(css,/@media\(max-width:900px\)/);
  assert.match(css,/@media\(max-width:520px\)/);
  assert.match(css,/overflow-x:auto/);
});

test("no unrelated legacy table definition or migration was changed by this phase",()=>{
  const altered=[...migration.matchAll(/alter table\s+public\.([a-z0-9_]+)/gi)].map(match=>match[1]);
  assert.deepEqual([...new Set(altered)],["projects"]);
  assert.doesNotMatch(migration,/alter table public\.(profiles|expenses|employees|payroll|assets)\b/i);
  assert.doesNotMatch(migration,/create policy\b|drop policy\b/i);
});
