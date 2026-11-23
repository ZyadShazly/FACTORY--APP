import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const workspace = await readFile(new URL("../src/v22/projectWorkspace.jsx", import.meta.url), "utf8");
const procurementMigration = await readFile(new URL("../supabase/migrations/20260720100200_procurement_workspace_v2.sql", import.meta.url), "utf8");

test("project materials tab reads project-scoped procurement orders and their lines", () => {
  assert.match(workspace, /ProjectMaterialsPurchasesTab project=\{project\}/);
  assert.match(workspace, /supabase\.rpc\("get_procurement_workspace_v2",\s*\{\s*target_project:project\.id\s*\}\)/);
  assert.match(workspace, /workspace\.order_items\.filter\(item=>item\.purchase_order_id===order\.id\)/);
  assert.match(workspace, /workspace\.invoices\.filter\(invoice=>invoice\.purchase_order_id===order\.id\)/);
  assert.match(procurementMigration, /create or replace function public\.get_procurement_workspace_v2\(target_project uuid default null\)/);
  assert.match(procurementMigration, /private\.project_can_view\(target_project\)/);
  assert.match(procurementMigration, /where target_project is null or o\.project_id=target_project/);
});

test("project purchase display is read-only and respects financial visibility", () => {
  const start = workspace.indexOf("function ProjectMaterialsPurchasesTab");
  const end = workspace.indexOf("export function ProjectWorkspace", start);
  assert.ok(start >= 0 && end > start, "project purchases component must exist");
  const component = workspace.slice(start, end);
  assert.doesNotMatch(component, /\.from\(["'](?:purchase_orders|purchase_order_items|supplier_invoices)["']\)\.(?:insert|update|delete)/);
  assert.doesNotMatch(component, /save_project_actual_cost|approve_project_actual_cost|save_supplier_invoice/);
  assert.match(component, /canViewFinancials && <span>الإجمالي/);
  assert.match(component, /canViewFinancials \? " × "/);
  assert.match(component, /لا ينشئ قيدًا محاسبيًا أو تكلفة فعلية إضافية/);
});

test("failed procurement reads are not misrepresented as an empty purchase list", () => {
  const start = workspace.indexOf("function ProjectMaterialsPurchasesTab");
  const end = workspace.indexOf("export function ProjectWorkspace", start);
  const component = workspace.slice(start, end);
  assert.match(component, /if \(result\.error\)/);
  assert.match(component, /لم نعرض رسالة «لا توجد مشتريات»/);
});
