import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const foundation = fs.readFileSync("src/ui/foundation.jsx", "utf8");
const exportsFile = fs.readFileSync("src/ui/index.js", "utf8");
const css = fs.readFileSync("src/ui/foundation.css", "utf8");
const styles = fs.readFileSync("src/styles.css", "utf8");
const designSystem = fs.readFileSync("src/design-system.css", "utf8");
const operationalUi = fs.readFileSync("src/operational/ui.jsx", "utf8");

const requiredComponents = [
  "PageHeader",
  "KpiGrid",
  "KpiCard",
  "PrimaryActionBar",
  "SearchFilterBar",
  "StatusBadge",
  "EmptyState",
  "DetailsDrawer",
  "ArchiveSection",
  "DependencySummary",
  "HelpText",
  "ResponsiveTable",
  "ResponsiveCardGrid",
];

function cssVariable(source, name) {
  return source.match(new RegExp(`${name}:\\s*(#[0-9a-f]{6})`, "i"))?.[1];
}

function luminance(hex) {
  const channels = hex.match(/[0-9a-f]{2}/gi).map((value) => Number.parseInt(value, 16) / 255);
  const linear = channels.map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  return (0.2126 * linear[0]) + (0.7152 * linear[1]) + (0.0722 * linear[2]);
}

function contrastRatio(foreground, background) {
  const values = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

test("foundation exports every required presentation component", () => {
  for (const component of requiredComponents) {
    assert.match(foundation, new RegExp(`export function ${component}\\b`), component);
    assert.match(exportsFile, new RegExp(`\\b${component}\\b`), component);
  }
  assert.match(operationalUi, /from "\.\.\/ui\/index\.js"/);
});

test("foundation is presentation-only and contains no data access", () => {
  assert.doesNotMatch(foundation, /supabase|\.rpc\(|\.from\(|fetch\(|localStorage|sessionStorage/);
  assert.doesNotMatch(foundation, /project_id|employee_id|warehouse_id|purchase_order/);
});

test("KPI foundation documents the five-card ceiling", () => {
  assert.match(foundation, /export const MAX_KPI_CARDS = 5/);
  assert.match(foundation, /data-max-kpis=\{MAX_KPI_CARDS\}/);
  assert.match(css, /\.nui-kpi-grid\s*\{/);
});

test("status, drawer, and empty states expose accessible text", () => {
  assert.match(foundation, /export function StatusBadge[\s\S]*?className=\{classNames\("nui-status-badge"[\s\S]*?<span>\{label\}<\/span>/);
  assert.match(foundation, /role="dialog"/);
  assert.match(foundation, /aria-modal="true"/);
  assert.match(foundation, /aria-labelledby=\{titleId\}/);
  assert.match(foundation, /aria-describedby=\{description \? descriptionId : undefined\}/);
  assert.match(foundation, /aria-label=\{title\}/);
  assert.match(foundation, /closeOnEscape/);
  assert.match(foundation, /closeButtonRef\.current\?\.focus\(\)/);
  assert.match(foundation, /previousFocus\?\.focus\?\.\(\)/);
});

test("archive and dependency presentations keep history on demand", () => {
  assert.match(foundation, /<details className=\{classNames\("nui-archive-section"/);
  assert.match(foundation, /defaultOpen = false/);
  assert.match(foundation, /className=\{classNames\("nui-dependency-summary"/);
  assert.match(foundation, /item\.action/);
});

test("responsive table and cards use intentional contained overflow", () => {
  assert.match(css, /\.nui-responsive-table\s*\{[\s\S]*?overflow-x: auto/);
  assert.match(css, /@media \(max-width: 760px\)/);
  assert.match(css, /@media \(max-width: 480px\)/);
  assert.match(css, /\.nui-responsive-card-grid/);
  assert.match(styles, /@import '\.\/ui\/foundation\.css'/);
});

test("foundation status text meets normal-text contrast", () => {
  const pairs = [
    ["--nui-success-text", "--color-success-soft"],
    ["--nui-info-text", "--color-info-soft"],
    ["--nui-warning-text", "--color-warning-soft"],
    ["--nui-danger-text", "--color-danger-soft"],
    ["--nui-neutral-text", "--color-neutral-soft"],
  ];
  for (const [foregroundName, backgroundName] of pairs) {
    const foreground = cssVariable(css, foregroundName);
    const background = cssVariable(designSystem, backgroundName);
    assert.ok(foreground && background, `${foregroundName}/${backgroundName} must be defined`);
    assert.ok(contrastRatio(foreground, background) >= 4.5, `${foregroundName} must meet WCAG AA`);
  }
});
