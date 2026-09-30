import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

import { APP_TAB_IDS, APP_TAB_LABELS } from "../src/app/navigationRegistry.js";
import { NAV_GROUPS } from "../src/navigation.js";
import { permissionsForProfile } from "../src/app/permissions.js";

const ui = fs.readFileSync("src/accounting/AccountingWorkspace.jsx", "utf8");
const css = fs.readFileSync("src/accounting/accountingWorkspace.css", "utf8");
const app = fs.readFileSync("src/AppMonolith.jsx", "utf8");

test("accounting workspace is registered under Finance", () => {
  assert.ok(APP_TAB_IDS.includes("accounting"));
  assert.equal(APP_TAB_LABELS.accounting, "المحاسبة");
  const finance = NAV_GROUPS.find((group) => group.id === "finance");
  assert.ok(finance);
  assert.ok(finance.pages.includes("accounting"));
});

test("accounting workspace uses protected COA RPCs only", () => {
  assert.match(ui, /supabase\.rpc\("get_accounting_accounts"\)/);
  assert.match(ui, /supabase\.rpc\("create_accounting_account"/);
  assert.match(ui, /supabase\.rpc\("update_accounting_account"/);
  assert.match(ui, /supabase\.rpc\("owner_convert_account_to_group"/);
  assert.doesNotMatch(ui, /supabase\.from\("accounting_accounts"\)/);
});

test("accounting workspace exposes accounts, journal, reports and mappings tabs", () => {
  assert.match(ui, /أقسام المحاسبة/);
  assert.match(ui, /شجرة الحسابات/);
  assert.match(ui, /القيود اليومية/);
  assert.match(ui, /<JournalWorkspace/);
  assert.match(ui, /التقارير المحاسبية/);
  assert.match(ui, /<AccountingReportsWorkspace/);
  assert.match(ui, /ربط الحسابات/);
  assert.match(ui, /<AccountingMappingsWorkspace/);
});

test("COA UI supports tree navigation, search and filters", () => {
  assert.match(ui, /buildVisibleRows/);
  assert.match(ui, /فتح الكل/);
  assert.match(ui, /طي الكل/);
  assert.match(ui, /بحث بالكود أو اسم الحساب/);
  assert.match(ui, /كل أنواع الحسابات/);
  assert.match(ui, /accounting-expand/);
  assert.match(css, /accounting-account-cell/);
});

test("COA UI supports add, subaccount, edit, activation and owner group conversion", () => {
  assert.match(ui, />إضافة حساب</);
  assert.match(ui, />فرعي</);
  assert.match(ui, />تعديل</);
  assert.match(ui, /row\.is_active \? "تعطيل" : "تفعيل"/);
  assert.match(ui, /تحويل لتجميعي/);
  assert.match(ui, /سبب التحويل/);
  assert.match(ui, /profile\?\.role === "owner"/);
});

test("COA UI does not invent balances before the GL is live", () => {
  assert.match(ui, /accounting-balance-placeholder/);
  assert.match(ui, /الرصيد سيظهر هنا بعد تشغيل دفتر الأستاذ والقيود/);
  assert.match(ui, /المحاسبة غير مفعلة للترحيل التلقائي بعد/);
});

test("accounting page is mounted in the current application shell", () => {
  assert.match(app, /import \{ AccountingWorkspace \} from "\.\/accounting\/AccountingWorkspace"/);
  assert.match(app, /activeTab === "accounting"[\s\S]*permissions\.accounting_view[\s\S]*<AccountingWorkspace/);
});

test("accountant sees accounting by default and production never does", () => {
  const accountant = permissionsForProfile({ role: "accountant", status: "active", permissions: {} });
  const production = permissionsForProfile({
    role: "production",
    status: "active",
    permissions: { pages: ["accounting", "production"], accounting_view: true },
  });

  assert.ok(accountant.pages.includes("accounting"));
  assert.equal(accountant.accounting_view, true);
  assert.ok(!production.pages.includes("accounting"));
  assert.equal(production.accounting_view, false);
});

test("manager accounting navigation follows explicit permission while owner always sees it", () => {
  const managerOff = permissionsForProfile({ role: "manager", status: "active", permissions: {} });
  const managerOn = permissionsForProfile({
    role: "manager",
    status: "active",
    permissions: { accounting_view: true },
  });
  const owner = permissionsForProfile({ role: "owner", status: "active", permissions: {} });

  assert.ok(!managerOff.pages.includes("accounting"));
  assert.ok(managerOn.pages.includes("accounting"));
  assert.ok(owner.pages.includes("accounting"));
});


test("runtime sidebar navigation includes accounting under the finance flow", () => {
  assert.match(app, /\{ id: "accounting", label: "المحاسبة", icon: BookOpen \}/);
  assert.match(app, /\{ id: "customers"[\s\S]*\{ id: "accounting"[\s\S]*\{ id: "employees"/);
});
