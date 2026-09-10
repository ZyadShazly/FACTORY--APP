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

test("closed project revenue contributes to customer due in UI and database canonical balance", () => {
  const balance = customerBalances("c1", {
    sales: [{ customer_id: "c1", status: "posted", total: 500 }],
    rentals: [],
    projects: [{ customer_id: "c1", lifecycle: "closed", revenue: 15000 }],
    customerReceipts: [{ customer_id: "c1", status: "posted", amount: 1000, transaction_classification: "settlement", settlement_amount: 1000, allocated_advance_amount: 0, advance_amount: 0 }],
  });
  assert.equal(balance.due, 14500);
  assert.match(closedProjectMigration, /p\.lifecycle='closed'/);
  assert.match(closedProjectMigration, /select sum\(p\.revenue\)/);
});
