import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { budgetLineTotals, budgetTotals, compareBudgetItems, BUDGET_CATEGORIES, BUDGET_TRANSITIONS } from "../src/v22/projectBudgetDomain.js";

const migration = await readFile(new URL("../supabase/migrations/202607190003_project_estimated_budget.sql", import.meta.url),"utf8");
const workspace = await readFile(new URL("../src/v22/projectWorkspace.jsx", import.meta.url),"utf8");
const budgetUi = await readFile(new URL("../src/v22/projectBudget.jsx", import.meta.url),"utf8");
const css = await readFile(new URL("../src/v22/projectBudget.css", import.meta.url),"utf8");
const actionPermissionRules = await readFile(new URL("../src/app/actionPermissions.js", import.meta.url),"utf8");
const docs = await readFile(new URL("../docs/PROJECT_ESTIMATED_BUDGET.md", import.meta.url),"utf8");

test("line calculations round base, waste, and total consistently",()=>{
  assert.deepEqual(budgetLineTotals({quantity:3,unit_cost:10.115,waste_percentage:10}),{baseCost:30.35,wasteAmount:3.04,totalWithWaste:33.39});
  assert.throws(()=>budgetLineTotals({quantity:-1,unit_cost:2,waste_percentage:0}));
  assert.throws(()=>budgetLineTotals({quantity:1,unit_cost:2,waste_percentage:101}));
  assert.throws(()=>budgetLineTotals({quantity:Infinity,unit_cost:2,waste_percentage:0}));
});

test("budget totals avoid double applying fixed and percentage adjustments",()=>{
  const items=[{quantity:2,unit_cost:100,waste_percentage:10}];
  assert.deepEqual(budgetTotals(items,{contingency_mode:"percentage",contingency_percentage:10,overhead_mode:"fixed",overhead_amount:30,target_profit_mode:"percentage",target_profit_percentage:20}),{subtotal:220,contingency:22,overhead:30,expectedTotalCost:272,targetProfit:54.4,targetSalePrice:326.4});
});

test("required material, production, logistics, labor, equipment, and other categories exist",()=>{
  for(const category of ["wood","mdf","hpl","carpentry","cnc","subcontractor","transportation","site_expenses","factory_employees","daily_labor","rented_equipment","approved_asset_usage_cost","depreciation_allocation","direct_expenses","contingency","overhead"]) assert.ok(BUDGET_CATEGORIES[category],category);
  assert.equal(BUDGET_CATEGORIES.asset_custody,undefined);
});

test("version comparison reports additions, removals, and numeric variances",()=>{
  const rows=compareBudgetItems([{item_code:"A",description:"قديم",quantity:1,unit_cost:100,waste_percentage:0},{item_code:"B",description:"محذوف",quantity:1,unit_cost:20,waste_percentage:0}],[{item_code:"A",description:"جديد",quantity:2,unit_cost:75,waste_percentage:0},{item_code:"C",description:"مضاف",quantity:1,unit_cost:10,waste_percentage:0}]);
  assert.equal(rows.find((row)=>row.compare_key==="A").variance_amount,50);
  assert.equal(rows.find((row)=>row.compare_key==="B").change_type,"removed");
  assert.equal(rows.find((row)=>row.compare_key==="C").change_type,"added");
});

test("workflow states are strict and historical states are terminal",()=>{
  assert.deepEqual(BUDGET_TRANSITIONS.draft,["submitted","cancelled"]);
  assert.deepEqual(BUDGET_TRANSITIONS.submitted,["approved","rejected"]);
  assert.deepEqual(BUDGET_TRANSITIONS.rejected,[]);
  assert.deepEqual(BUDGET_TRANSITIONS.superseded,[]);
  assert.match(migration,/Approved budgets are immutable/);
  assert.match(migration,/Historical budget versions are immutable/);
});

test("migration is additive after 001 and 002 and preserves Project Workspace data",()=>{
  assert.match(migration,/requires the merged PR #13 Project Workspace tables/);
  assert.doesNotMatch(migration,/drop table|truncate table|delete from public\.projects|alter table public\.projects rename/i);
  for(const table of ["project_budget_versions","project_budget_sections","project_budget_items","project_budget_templates","project_budget_template_sections","project_budget_template_items"]) assert.match(migration,new RegExp(`create table if not exists public\\.${table}`));
});

test("sequential versions and concurrent approval use project and row locks",()=>{
  const create=migration.slice(migration.indexOf("create or replace function public.create_project_budget_draft"),migration.indexOf("create or replace function public.copy_project_budget_version"));
  assert.match(create,/from public\.projects where id=target_project for update/);
  assert.match(create,/coalesce\(max\(version_number\),0\)\+1/);
  const approve=migration.slice(migration.indexOf("create or replace function public.approve_project_budget"),migration.indexOf("create or replace function public.reject_project_budget"));
  assert.match(approve,/from public\.project_budget_versions where id=target_version for update/);
  assert.match(approve,/from public\.projects where id=v\.project_id for update/);
  assert.match(approve,/status='superseded'/);
  assert.match(migration,/project_budget_one_active_approved_idx.*where status='approved'/);
});

test("submission, approval, rejection, and draft cancellation validate state",()=>{
  assert.match(migration,/Budget submission requires at least one valid positive item/);
  assert.match(migration,/Only a submitted budget may be approved/);
  assert.match(migration,/Submission calculated and froze the totals/);
  assert.match(migration,/A rejection reason is required/);
  assert.match(migration,/Only a draft budget may be cancelled/);
  assert.match(migration,/deleted_empty_draft/);
});

test("new activation requires an approved positive budget while legacy and Owner override are explicit",()=>{
  assert.match(migration,/budget_ready:=approved\.id is not null and approved\.expected_total_cost>0 and valid_lines>0/);
  assert.match(migration,/base_ready and \(budget_ready or p\.legacy_activation_exempt or override_ready\)/);
  assert.match(migration,/public\.current_identity_role\(\)<>'owner'/);
  assert.match(migration,/Activation budget override is one-time and already recorded/);
  assert.match(migration,/A mandatory activation override reason is required/);
  assert.match(workspace,/إعفاء التفعيل محفوظ وصريح/);
});

test("permission defaults separate Owner, Manager, Accountant, and Production",()=>{
  for(const permission of ["project_budget_view","project_budget_create","project_budget_edit","project_budget_submit","project_budget_approve","project_budget_reject","project_budget_view_financials","project_budget_manage_templates","project_budget_override_activation"]) assert.match(actionPermissionRules,new RegExp(`"${permission}"`));
  assert.match(actionPermissionRules,/\["project_budget_approve",\s*"project_budget_reject"\]/);
  assert.match(actionPermissionRules,/profile\?\.permissions\?\.\[key\] === true/);
  assert.match(actionPermissionRules,/resolved\.project_budget_override_activation = false/);
  assert.match(migration,/when 'manager' then permission_name=any/);
  assert.match(migration,/permission_name=any\(array\['project_budget_approve','project_budget_reject'\]\)/);
  assert.doesNotMatch(migration,/permission_name=any\(array\['project_budget_override_activation'/);
  assert.match(migration,/when 'production' then coalesce\(\(permissions->>permission_name\)::boolean,false\)/);
});

test("RLS blocks direct access and safe projections redact every financial field",()=>{
  for(const table of ["project_budget_versions","project_budget_sections","project_budget_items","project_budget_templates","project_budget_template_sections","project_budget_template_items","project_cost_source_contracts"]){
    assert.match(migration,new RegExp(`alter table public\\.${table} enable row level security`));
    assert.match(migration,new RegExp(`revoke all on table public\\.${table} from public,anon,authenticated`));
  }
  assert.match(migration,/to_jsonb\(v\)-array\['subtotal','contingency_amount','contingency_percentage','overhead_amount','overhead_percentage','expected_total_cost','target_profit_amount','target_profit_percentage','target_sale_price'\]/);
  assert.match(migration,/to_jsonb\(i\)-array\['unit_cost','estimated_cost','waste_amount','total_with_waste'\]/);
});

test("all business RPCs are explicit and internal helpers are not API executable",()=>{
  for(const rpc of ["create_project_budget_draft","copy_project_budget_version","update_project_budget_header","save_project_budget_section","reorder_project_budget_sections","save_project_budget_item","reorder_project_budget_items","delete_project_budget_draft_item","submit_project_budget","approve_project_budget","reject_project_budget","cancel_project_budget_draft","create_budget_template_from_version","create_budget_from_template","get_project_budget_visible","compare_project_budget_versions","get_project_activation_readiness","override_project_activation_budget_requirement"]) assert.match(migration,new RegExp(`'${rpc}\\(`));
  for(const helper of ["project_budget_has_permission","project_budget_can","recalculate_project_budget","recalculate_project_budget_trigger","protect_project_budget_history","validate_project_cost_source","project_budget_activity"]) assert.match(migration,new RegExp(`revoke execute on function private\\.${helper}`));
  const functions=[...migration.matchAll(/create or replace function (?:public|private)\.[\s\S]*?\n\$\$;/g)].map((match)=>match[0]);
  for(const fn of functions) assert.match(fn,/set search_path =/);
});

test("Realtime uses the existing safe signal and never publishes financial tables",()=>{
  for(const table of ["project_budget_versions","project_budget_sections","project_budget_items"]) assert.match(migration,new RegExp(`project_realtime_signal after insert or update or delete on public\\.%I[\\s\\S]*${table}|array\\['project_budget_versions','project_budget_sections','project_budget_items'\\]`));
  assert.doesNotMatch(migration,/alter publication supabase_realtime add table public\.project_budget/);
  assert.doesNotMatch(budgetUi,/supabase\.channel/);
});

test("Actual Cost source contract prevents custody advances and double posting",()=>{
  assert.match(migration,/'employee_cash_custody_settlement_line','approved_settlement_line','approved'/);
  assert.match(migration,/Cash custody advance is a receivable, not Actual Cost/);
  assert.match(migration,/Every Actual Cost posting requires a unique source reference/);
  assert.match(migration,/project_costs_source_revision_unique/);
  assert.match(migration,/project_costs_source_reference_key_unique/);
  assert.match(migration,/estimated_budget_item_id uuid references public\.project_budget_items/);
  assert.doesNotMatch(migration,/create table if not exists public\.(employee_)?cash_custod/i);
  for(const phrase of ["advance amount","approved invoices","returned cash","excess employee claim","partial/full settlement","overdue","write-off"]) assert.match(docs,new RegExp(phrase,"i"));
});

test("covering indexes are unique and cover ordering, approvals, templates, and actor FKs",()=>{
  const names=[...migration.matchAll(/create (?:unique )?index if not exists ([a-z0-9_]+)/gi)].map((match)=>match[1]);
  assert.equal(new Set(names).size,names.length);
  for(const column of ["created_by","updated_by","submitted_by","approved_by","rejected_by","supplier_id","responsible_department_id","milestone_id"]) assert.match(migration,new RegExp(`project_budget_[a-z0-9_]+_${column.replace('_id','')}[^\n]*|\\(${column}\\) where ${column} is not null`));
  for(const name of ["project_budget_sections_order_idx","project_budget_items_order_idx","project_budget_items_section_fk_idx","project_budget_items_category_idx","project_budget_templates_lookup_idx","project_budget_template_items_section_fk_idx","project_budget_versions_approval_idx"]) assert.ok(names.includes(name),name);
  assert.match(migration,/project_budget_items_section_fk_idx on public\.project_budget_items\(section_id,budget_version_id\)/);
  assert.match(migration,/project_budget_template_items_section_fk_idx on public\.project_budget_template_items\(template_section_id,template_id\)/);
});

test("budget UI is active, modular, financial-aware, responsive, and protects approval order",()=>{
  assert.match(workspace,/tab === "budget" && <ProjectBudgetTab/);
  assert.doesNotMatch(workspace,/tab === "budget" && <ComingSoon/);
  for(const component of ["BudgetSummary","BudgetSections","BudgetItemTable","BudgetItemDialog","BudgetApprovalPanel","BudgetVersionHistory","BudgetVersionCompare","BudgetTemplatePicker","ActivationReadinessPanel"]) assert.match(budgetUi,new RegExp(`function ${component}`));
  assert.match(budgetUi,/dir="rtl"/);
  assert.match(budgetUi,/canViewFinancials/);
  assert.match(css,/@media\(max-width:760px\)/);
  assert.match(css,/@media\(max-width:430px\)/);
  assert.match(css,/overflow-x:auto/);
  assert.match(budgetUi,/أضف بند ميزانية واحدًا على الأقل قبل الإرسال/);
});
