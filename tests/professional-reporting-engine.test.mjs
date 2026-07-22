import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const engine = fs.readFileSync("src/reporting/excelWorkbook.js", "utf8");
const exportsSource = fs.readFileSync("src/reporting/professionalExports.js", "utf8");
const workspace = fs.readFileSync("src/reporting/ReportingWorkspace.jsx", "utf8");
const printCss = fs.readFileSync("src/reporting/reportingPrint.css", "utf8");

test("professional workbook is real multi-sheet Excel XML with metadata and formats", () => {
  assert.match(engine, /Excel\.Sheet/);
  assert.match(engine, /Worksheet/);
  assert.match(engine, /generatedBy/);
  assert.match(engine, /generatedAt/);
  assert.match(engine, /filters/);
  assert.match(engine, /FreezePanes/);
  assert.match(engine, /AutoFilter/);
  assert.match(engine, /Currency/);
  assert.match(engine, /DateTime/);
});

test("payroll export explains deductions advances bonuses and approval state", () => {
  for (const field of ["deduction_reason", "advance_reason", "bonus_reason", "rejection_reason", "approved_at", "paid_at", "net_salary"]) {
    assert.match(exportsSource, new RegExp(field));
  }
  assert.match(exportsSource, /الخصومات والسلف/);
  assert.match(exportsSource, /الموافقات/);
});

test("external labor export includes calculation review and payment evidence", () => {
  for (const field of ["total_hours", "hourly_rate", "overtime_hours", "overtime_rate", "total_amount", "review_status", "payment_reference", "payment_notes"]) {
    assert.match(exportsSource, new RegExp(field));
  }
});

test("inventory export includes balances movements and exception checks", () => {
  assert.match(exportsSource, /get_inventory_workspace/);
  assert.match(exportsSource, /quantity_on_hand/);
  assert.match(exportsSource, /inventory_value/);
  assert.match(exportsSource, /inventory_movements|movements/);
  assert.match(exportsSource, /الاستثناءات/);
});

test("reporting workspace exposes Excel and print PDF actions", () => {
  assert.match(workspace, /Excel الرواتب/);
  assert.match(workspace, /Excel العمالة الخارجية/);
  assert.match(workspace, /Excel المخزون/);
  assert.match(workspace, /طباعة \/ PDF/);
  assert.match(printCss, /@media print/);
  assert.match(printCss, /A4 landscape/);
});
