import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { aggregateInventoryByMaterial } from "../src/domain/inventoryBalances.js";
import { customerBalances } from "../src/domain/commercialBalances.js";

const app = await readFile(new URL("../src/AppMonolith.jsx", import.meta.url), "utf8");
const assets = await readFile(new URL("../src/assets/AssetsPage.jsx", import.meta.url), "utf8");
const calendar = await readFile(new URL("../src/v23/workCalendar.jsx", import.meta.url), "utf8");
const exportsUi = await readFile(new URL("../src/reporting/professionalExports.js", import.meta.url), "utf8");
const reversalMigration = await readFile(new URL("../supabase/migrations/20260910211643_fix_commercial_reversal_target_id.sql", import.meta.url), "utf8");
const payrollMigration = await readFile(new URL("../supabase/migrations/20260910212219_fix_payroll_calendar_review_permission.sql", import.meta.url), "utf8");
const laborExportMigration = await readFile(new URL("../supabase/migrations/20260910212414_fix_external_labor_export_permission.sql", import.meta.url), "utf8");
const closedProjectMigration = await readFile(new URL("../supabase/migrations/20260910212126_fix_closed_project_customer_due.sql", import.meta.url), "utf8");
const unitAwareBudgetMigration = await readFile(new URL("../supabase/migrations/20260911004500_restore_procurement_budget_unit_comparability.sql", import.meta.url), "utf8");
const projectAdvanceMigration = await readFile(new URL("../supabase/migrations/20260911005500_project_customer_advance_allocation.sql", import.meta.url), "utf8");

test("explicit zero sale price is rejected instead of falling back to product price", () => {
  assert.match(app, /form\.unitPrice === "" \? Number\(selectedProduct\.selling_price\) : num\(form\.unitPrice\)/);
  assert.match(app, /unitPrice <= 0/);
});

test("commercial reversals use a distinct local id and preserve reversal guards", () => {
  assert.match(reversalMigration, /requested_id uuid:=target_id/);
  assert.match(reversalMigration, /where id=requested_id and status='allocated'/);
  assert.match(reversalMigration, /where id=requested_id and status='posted'/);
  assert.match(reversalMigration, /Reverse customer advance allocations first/);
  assert.match(reversalMigration, /Reverse supplier advance allocations first/);
});

test("payroll review resolves calendar internally without granting calendar-view access", () => {
  assert.match(payrollMigration, /private\.resolve_work_calendar_for_payroll/);
  assert.match(payrollMigration, /revoke all on function private\.resolve_work_calendar_for_payroll\(uuid,date,date,bigint\) from public,anon,authenticated/);
  assert.match(payrollMigration, /from private\.resolve_work_calendar_for_payroll/);
});

test("external labor export uses protected RPC instead of a direct projects join", () => {
  assert.match(exportsUi, /supabase\.rpc\("get_external_labor_export"/);
  assert.doesNotMatch(exportsUi.slice(exportsUi.indexOf("exportExternalLaborWorkbook"), exportsUi.indexOf("function inventoryRows")), /project:projects/);
  assert.match(laborExportMigration, /create or replace function public\.get_external_labor_export/);
});

test("asset settlement quantity accepts integer and fractional quantities", () => {
  const settlementStart = assets.indexOf("function SettlementModal");
  const settlementSource = assets.slice(settlementStart, settlementStart + 1200);
  assert.match(settlementSource, /min="\.001" step="\.001" required/);
});

test("ordinary holidays do not carry hidden half-day hours", () => {
  assert.match(calendar, /half_day_mode:null,required_start_time:"",required_end_time:"",required_minutes:""/);
  assert.match(calendar, /const timed=\["half_day","working_day_override"\]\.includes\(holiday_type\)/);
});

test("material aggregate exposes weighted average inventory cost for product BOM costing", () => {
  const workspace = {
    items: [{ id: "i1", material_id: "m1", item_type: "raw_material", name: "MDF", unit: "لوح" }],
    balances: [
      { inventory_item_id: "i1", quantity_on_hand: 2, inventory_value: 20, warehouse_name: "A" },
      { inventory_item_id: "i1", quantity_on_hand: 3, inventory_value: 45, warehouse_name: "B" },
    ],
  };
  const material = aggregateInventoryByMaterial(workspace).get("m1");
  assert.equal(material.quantityOnHand, 5);
  assert.equal(material.inventoryValue, 65);
  assert.equal(material.averageUnitCost, 13);
  assert.match(app, /materialCurrentUnitCost/);
  assert.match(app, /averageUnitCost/);
});

test("closed project revenue contributes to customer due and visible customer ledger", () => {
  const balance = customerBalances("c1", {
    sales: [{ customer_id: "c1", status: "posted", total: 500 }],
    rentals: [],
    projects: [{ customer_id: "c1", lifecycle: "closed", revenue: 15000 }],
    customerReceipts: [{ customer_id: "c1", status: "posted", amount: 1000, transaction_classification: "settlement", settlement_amount: 1000, allocated_advance_amount: 0, advance_amount: 0 }],
  });
  assert.equal(balance.due, 14500);
  assert.match(closedProjectMigration, /p\.lifecycle='closed'/);
  assert.match(closedProjectMigration, /select sum\(p\.revenue\)/);
  assert.match(app, /function customerProjectTotal/);
  assert.match(app, /إجمالي المستحقات/);
  assert.match(app, /type: "إقفال مشروع"/);
  assert.match(app, /customerSaleTotal\(c\.id, data\) \+ customerRentalTotal\(c\.id, data\) \+ customerProjectTotal\(c\.id, data\)/);
});

test("customer advance can settle a closed project charge", () => {
  const balance = customerBalances("c1", {
    sales: [],
    rentals: [],
    projects: [{ customer_id: "c1", lifecycle: "closed", revenue: 15000 }],
    customerReceipts: [{
      customer_id: "c1", status: "posted", amount: 500,
      transaction_classification: "advance", settlement_amount: 0,
      advance_amount: 500, allocated_advance_amount: 100,
    }],
  });
  assert.equal(balance.due, 14900);
  assert.equal(balance.advance, 400);
  assert.match(projectAdvanceMigration, /target_type in \('sale','rental','project'\)/);
  assert.match(projectAdvanceMigration, /when target_type='project'/);
  assert.match(projectAdvanceMigration, /'type','project'/);
  assert.match(projectAdvanceMigration, /elsif target_type='project'/);
  assert.match(projectAdvanceMigration, /private\.customer_advance_target_remaining\('project'/);
});

test("procurement guard keeps unit-aware quantity checks while blocking unlinked lines", () => {
  assert.match(unitAwareBudgetMigration, /requested_unit_count/);
  assert.match(unitAwareBudgetMigration, /prior_unit_count/);
  assert.match(unitAwareBudgetMigration, /quantity_is_comparable/);
  assert.match(unitAwareBudgetMigration, /c\.quantity_is_comparable and c\.prior_quantity\+c\.requested_quantity>c\.budget_quantity/);
  assert.match(unitAwareBudgetMigration, /unlinked_budget_item/);
  assert.match(unitAwareBudgetMigration, /invalid_budget_link/);
  assert.match(unitAwareBudgetMigration, /project_total/);
});

test("reversed customer and supplier cash rows do not reduce the visible ledgers twice", () => {
  assert.match(app, /r\.status === "reversed" \? 0 : -r\.amount/);
  assert.match(app, /p\.status === "reversed" \? 0 : -p\.amount/);
});
