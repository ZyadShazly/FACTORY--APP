import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  calculatedMilestoneProgress, effectiveProjectProgress, lifecycleNeedsReason,
  PROJECT_LIFECYCLE_TRANSITIONS,
} from "../src/v22/projectDomain.js";

const migration = await readFile(new URL("../supabase/migrations/202607190001_project_workspace_upgrade.sql", import.meta.url), "utf8");
const projects = await readFile(new URL("../src/v22/projects.jsx", import.meta.url), "utf8");
const workspace = await readFile(new URL("../src/v22/projectWorkspace.jsx", import.meta.url), "utf8");
const realtime = await readFile(new URL("../src/realtime.js", import.meta.url), "utf8");
const css = await readFile(new URL("../src/v22/projectWorkspace.css", import.meta.url), "utf8");
const docs = await readFile(new URL("../docs/PROJECT_WORKSPACE_FOUNDATION.md", import.meta.url), "utf8");

test("existing projects preserve IDs, legacy stages, and progress during migration", () => {
  assert.doesNotMatch(migration, /drop table\s+public\.projects/i);
  assert.doesNotMatch(migration, /alter table public\.projects rename column/i);
  assert.match(migration, /set execution_stage = status/);
  assert.match(migration, /manual_progress_percentage = coalesce\(manual_progress_percentage, progress_percentage, 0\)/);
  assert.match(migration, /effective_progress_percentage = coalesce\(effective_progress_percentage, progress_percentage, 0\)/);
  assert.match(migration, /legacy_activation_exempt = coalesce\(legacy_activation_exempt, true\)/);
});

test("legacy status meaning has an exact non-destructive lifecycle mapping", () => {
  for (const [stage, lifecycle] of Object.entries({ design:"planning",approval:"planning",manufacturing:"active",painting:"active",installation:"active",delivered:"completed",on_hold:"on_hold",cancelled:"cancelled" })) {
    assert.match(migration, new RegExp(`when '${stage}' then '${lifecycle}'`));
  }
  assert.doesNotMatch(migration, /when 'delivered' then 'closed'/);
  assert.match(docs, /delivered \| delivered \| completed/);
});

test("lifecycle transition matrix is exact and terminal states are immutable", () => {
  assert.deepEqual(PROJECT_LIFECYCLE_TRANSITIONS.draft,["planning","cancelled"]);
  assert.deepEqual(PROJECT_LIFECYCLE_TRANSITIONS.planning,["draft","ready_for_activation","cancelled"]);
  assert.deepEqual(PROJECT_LIFECYCLE_TRANSITIONS.ready_for_activation,["planning","active","cancelled"]);
  assert.deepEqual(PROJECT_LIFECYCLE_TRANSITIONS.active,["on_hold","completed"]);
  assert.deepEqual(PROJECT_LIFECYCLE_TRANSITIONS.on_hold,["active","cancelled"]);
  assert.deepEqual(PROJECT_LIFECYCLE_TRANSITIONS.completed,["active","closed"]);
  assert.deepEqual(PROJECT_LIFECYCLE_TRANSITIONS.closed,[]);
  assert.deepEqual(PROJECT_LIFECYCLE_TRANSITIONS.cancelled,[]);
  assert.match(migration, /Invalid project lifecycle transition/);
  assert.match(migration, /Final project lifecycle cannot change/);
});

test("exceptional lifecycle actions require reasons and Owner controls reopen", () => {
  assert.equal(lifecycleNeedsReason("completed","active"),true);
  assert.equal(lifecycleNeedsReason("on_hold","cancelled"),true);
  assert.equal(lifecycleNeedsReason("completed","closed"),true);
  assert.match(migration, /A mandatory reason is required for this transition/);
  assert.match(migration, /Only Owner may reopen a completed project/);
  assert.match(migration, /actor_role<>'owner' or not public\.has_permission\('projects_override'\)/);
});

test("activation readiness is extensible without faking budget approval", () => {
  assert.match(migration, /create or replace function public\.project_activation_readiness/);
  assert.match(migration, /'estimated_budget_approval'.*'implemented',false.*'blocking',false.*'not_implemented'/s);
  assert.match(migration, /implemented_ready or p\.legacy_activation_exempt/);
  assert.doesNotMatch(workspace, /ميزانية معتمدة.*نعم/);
});

test("frontend project mutations use protected RPCs and no direct projects writes remain", () => {
  assert.match(projects, /rpc\("create_project_draft"/);
  for (const rpc of ["update_project_details","transition_project_lifecycle","update_project_execution_stage","update_project_progress","save_project_milestone","add_project_member","remove_project_member"]) assert.match(workspace,new RegExp(`"${rpc}"`));
  assert.doesNotMatch(projects, /from\("projects"\)\.(insert|update|delete)/);
  assert.doesNotMatch(workspace, /from\("projects"\)\.(insert|update|delete)/);
  assert.doesNotMatch(workspace, /window\.location\.reload/);
});

test("progress supports manual, automatic, and reasoned hybrid behavior", () => {
  const milestones=[{status:"completed",weight_percentage:40,progress_percentage:100},{status:"in_progress",weight_percentage:60,progress_percentage:50},{status:"cancelled",weight_percentage:100,progress_percentage:100}];
  assert.equal(calculatedMilestoneProgress(milestones),70);
  assert.equal(effectiveProjectProgress({mode:"manual",manual:42,calculated:70}),42);
  assert.equal(effectiveProjectProgress({mode:"automatic",manual:42,calculated:70}),70);
  assert.equal(effectiveProjectProgress({mode:"hybrid",manual:42,calculated:70,overrideReason:null}),70);
  assert.equal(effectiveProjectProgress({mode:"hybrid",manual:42,calculated:70,overrideReason:"قرار ميداني"}),42);
  assert.match(migration, /financial|الإنفاق/i);
  assert.match(migration, /A reason is required for a hybrid progress override/);
});

test("milestones enforce weights, dates, status semantics, ordering, and audit", () => {
  assert.match(migration, /Active milestone weights cannot exceed 100%%/);
  assert.match(migration, /planned_end_date is null or planned_start_date is null or planned_end_date >= planned_start_date/);
  assert.match(migration, /status = 'completed' and progress_percentage = 100/);
  assert.match(migration, /project_milestones_project_order_idx.*project_id, sequence, id/s);
  assert.match(migration, /create trigger audit_changes after insert or update or delete on public\.project_milestones/);
});

test("membership is canonical, unique, project-scoped, and manager-consistent", () => {
  assert.match(migration, /profiles where id = new\.profile_id and employee_id = new\.employee_id/);
  assert.match(migration, /project_members_active_profile_unique/);
  assert.match(migration, /project_members_active_employee_unique/);
  assert.match(migration, /project_members_one_active_manager/);
  assert.match(migration, /update public\.projects set project_manager_id=target_profile/);
  assert.match(docs, /لا تمنحه العضوية أي صلاحية نظام عامة/i);
});

test("RLS and projection deny anon, require active visibility, and hide finance", () => {
  assert.match(migration, /revoke all on table public\.projects from anon, authenticated/);
  assert.match(migration, /private\.project_profile_active\(\)/);
  assert.match(migration, /private\.project_can_view\(p\.id\)/);
  assert.match(migration, /to_jsonb\(p\) - array\['expected_cost','actual_cost','revenue','profit'\]/);
  assert.match(migration, /to_jsonb\(current_row\)-array\['expected_cost','actual_cost','revenue','profit'\]/);
  assert.doesNotMatch(migration, /'before',to_jsonb\(current_row\),/);
  assert.match(migration, /project_milestones_select.*to authenticated.*private\.project_can_view/s);
  assert.match(migration, /project_members_select.*to authenticated.*private\.project_can_view/s);
});

test("operational projects cannot be hard deleted and every action is auditable", () => {
  assert.match(migration, /Projects cannot be hard deleted; use lifecycle cancellation/);
  assert.doesNotMatch(workspace, /حذف نهائي/);
  for (const action of ["project_created","details_changed","lifecycle_changed","execution_stage_changed","progress_updated","progress_overridden","milestone_created","team_member_added","team_member_removed","file_deleted"]) assert.match(migration,new RegExp(`'${action}'`));
  assert.match(migration, /execute function public\.audit_row_change\(\)/);
});

test("Realtime extends the central channel without duplicate subscriptions", () => {
  for (const [table,key] of [["project_milestones","projectMilestones"],["project_members","projectMembers"],["project_realtime_signal","projectRealtimeSignal"]]) {
    assert.match(realtime,new RegExp(`${table}: "${key}"`));
    assert.match(migration,new RegExp(`'${table}'`));
  }
  assert.match(workspace, /Promise\.all\(\[\.\.\.new Set\(keys\)\]/);
  assert.doesNotMatch(workspace, /supabase\.channel/);
});

test("non-financial editors never send hidden finance values", () => {
  assert.match(workspace, /permissions\.project_financials_view[\s\S]*Object\.fromEntries/);
  assert.match(workspace, /\["expected_cost","revenue"\]\.includes\(key\)/);
});

test("indexes are named once and internal helpers are not API executable", () => {
  const names=[...migration.matchAll(/create (?:unique )?index if not exists ([a-z0-9_]+)/gi)].map((match)=>match[1]);
  assert.equal(new Set(names).size,names.length);
  for(const fn of ["project_calculated_progress(uuid)","validate_project_milestone_weight()","refresh_project_progress_from_milestones()","validate_project_member_identity()","protect_project_workspace_fields()","emit_project_realtime_signal()","log_project_file_deleted()","log_project_file_uploaded()"]){
    assert.match(migration,new RegExp(`revoke execute on function public\\.${fn.replace(/[()]/g,(value)=>`\\${value}`)} from public,anon,authenticated;`));
  }
});

test("workspace is RTL, modular, responsive, and marks future modules honestly", () => {
  for(const label of ["نظرة عامة","مراحل التنفيذ","الفريق","الملفات","الخامات والمشتريات","الإنتاج","العمالة","المصروفات","العِدّة","الميزانية","التكلفة الفعلية","التقارير","سجل النشاط"]) assert.match(workspace,new RegExp(label));
  assert.match(workspace,/dir="rtl"/);
  assert.match(workspace,/قريبًا — لم تُنشأ بيانات تقديرية أو مالية وهمية/);
  assert.match(css,/@media\(max-width:760px\)/);
  assert.match(css,/@media\(max-width:430px\)/);
  assert.match(css,/overflow-x:auto/);
});

test("actual cost and factory labor remain documented extension contracts", () => {
  assert.match(docs,/source_type \+ source_id \+ allocation_revision/);
  assert.match(docs,/عهدة الأصل ليست تكلفة/);
  assert.match(docs,/days \| hours \| percentage/);
  assert.match(docs,/لم يُنفذ حساب شهري/);
});
