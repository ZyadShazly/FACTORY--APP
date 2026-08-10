import React, { useState, useEffect, useMemo, useCallback } from "react";
import { supabase } from "./supabaseClient";
import {
  LayoutDashboard, Package, Layers, Factory, ShoppingCart, Truck, Users,
  BarChart3, Plus, Trash2, AlertCircle, CheckCircle2, Wallet, Boxes,
  CalendarClock, ShieldCheck, Pencil, X, ReceiptText, ClipboardList,
  BriefcaseBusiness, FolderOpen, UserRoundCog, BadgeDollarSign, HardHat, ScrollText, ChevronDown, Settings, Wrench, Archive, RotateCcw,
} from "lucide-react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Legend,
} from "recharts";
import { ACTION_PERMISSIONS, actionPermissions, ConfirmDialog, Toast } from "./v22/shared";
import { ProjectsTab, ProjectFilesHub } from "./v22/projects";
import { EmployeesTab } from "./v22/payroll";
import { PayrollReviewTab as PayrollTab } from "./v22/PayrollReviewTab";
import { DailyLaborTab } from "./v22/dailyLabor";
import { AuditLogTab, PERMISSION_LABELS } from "./v22/audit";
import { demoData, demoProfile } from "./v22/demoData";
import { runCriticalMutation, syncMutation } from "./v22/mutations";
import { dataTableKeysForRole, resolveAllowedTab, TABLES } from "./realtime";
import { buildNavigationGroups, loadNavigationState, NAV_GROUPS, NAV_GROUP_STORAGE_KEY } from "./navigation";
import { canAssignRole, identityProtectionReason, isAdministrativeRole, MANAGER_ASSIGNABLE_ROLES, normalizeAccountPhone, PRODUCTION_ALLOWED_PAGES, SYSTEM_ROLES } from "./identity";
import { withTimeout } from "./bootstrap";
import { createTableFetcher, EMPTY_DATA } from "./app/dataBootstrap";
import { buildRealtimeChannelPlan, nextRealtimeState } from "./app/realtimeBootstrap";
import { useProfileBootstrap } from "./auth/useProfileBootstrap";
import { BootstrapFailure, BootstrapLoading } from "./auth/BootstrapScreens";
import { AppShell } from "./layout/AppShell";
import { SettingsPage } from "./settings/SettingsPage";
import { WorkCalendarTab } from "./v23/workCalendar";
import { AssetExternalConfirmation, AssetsPage } from "./assets/AssetsPage";
import { ReportingWorkspace } from "./reporting/ReportingWorkspace";
import { InventoryWorkspace } from "./operational/InventoryWorkspace";
import { MaterialsCatalogWorkspace } from "./operational/MaterialsCatalogWorkspace";
import { ProductionWorkspace } from "./operational/ProductionWorkspace";
import { ProcurementWorkspace } from "./operational/ProcurementWorkspace";
import { CommercialAdvancesPanel } from "./operational/CommercialAdvancesPanel";
import { ArchiveSection } from "./ui/foundation";
import { canonicalMaterialAlerts } from "./domain/inventoryBalances";
import { readWorkspaceLocation, workspaceUrl } from "./app/urlNavigation";
import { customerBalances, supplierBalances, transactionClassLabel } from "./domain/commercialBalances";
import { configureCurrency, formatMoney } from "./userExperience";

const V22_DEMO = (import.meta.env.DEV || import.meta.env.VITE_ENABLE_DEMO === "true") && new URLSearchParams(window.location.search).get("demo") === "v22";
const DEMO_ROLE = ["owner", "manager", "accountant", "production"].includes(new URLSearchParams(window.location.search).get("role")) ? new URLSearchParams(window.location.search).get("role") : "owner";
const DEMO_ACCOUNT_STATE = new URLSearchParams(window.location.search).get("accountState");
const DEMO_CONNECTION_STATE = new URLSearchParams(window.location.search).get("connection");
const ASSET_CONFIRMATION_MODE = new URLSearchParams(window.location.search).has("assetConfirmation");
const ASSET_QR_MODE = new URLSearchParams(window.location.search).has("assetQr");
const ACTIVE_DEMO_PROFILE = V22_DEMO ? {
  ...demoProfile,
  role: DEMO_ROLE,
  full_name: SYSTEM_ROLES[DEMO_ROLE]?.label || demoProfile.full_name,
  permissions: DEMO_ROLE === "production" ? { pages: ["production"] } : {},
} : demoProfile;

/* ---------------------------------- ثيم ---------------------------------- */
const C = {
  bg: "var(--color-app-bg)", panel: "var(--color-surface)", panelAlt: "var(--color-surface-muted)", border: "var(--color-border)",
  wood: "var(--color-wood)", woodDark: "var(--color-wood-dark)", brass: "var(--color-gold)",
  text: "var(--color-text)", muted: "var(--color-text-muted)", green: "var(--color-success)", red: "var(--color-danger)", blue: "var(--color-info)",
};

const num = (v) => { const n = parseFloat(v); return isFinite(n) ? n : 0; };
const fmt = (n) => (isFinite(n) ? n : 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const todayStr = () => new Date().toISOString().slice(0, 10);

const ROLES = SYSTEM_ROLES;
const NAV_BY_ROLE = {
  manager: ["dashboard", "projects", "projectFiles", "inventory", "purchases", "expenses", "materials", "products", "production", "sales", "rentals", "suppliers", "customers", "employees", "payroll", "dailyLabor", "reports", "auditLog", "team"],
  accountant: ["projects", "projectFiles", "inventory", "purchases", "expenses", "materials", "products", "production", "sales", "rentals", "suppliers", "customers", "employees", "payroll", "dailyLabor"],
  production: ["projects", "projectFiles", "inventory", "production"],
};
const ALL_PAGE_IDS = ["dashboard", "projects", "projectFiles", "inventory", "purchases", "expenses", "materials", "products", "production", "assets", "sales", "rentals", "suppliers", "customers", "employees", "workCalendar", "payroll", "dailyLabor", "reports", "auditLog", "team", "settings"];
const PAGE_LABELS = {
  projects: "المشاريع", projectFiles: "ملفات المشاريع", employees: "الموظفون", workCalendar: "تقويم العمل والعطلات", payroll: "المرتبات", dailyLabor: "العمالة اليومية", auditLog: "سجل التدقيق",
  dashboard: "لوحة التحكم", inventory: "المخزون", purchases: "المشتريات", expenses: "المصروفات", materials: "المواد الخام", products: "المنتجات والتكلفة",
  production: "أوامر الإنتاج", assets: "الأصول والعِدّة", sales: "المبيعات", rentals: "الإيجارات",
  suppliers: "الموردين", customers: "العملاء", reports: "التقارير", team: "الفريق والصلاحيات", settings: "الإعدادات", assetAlerts: "تنبيهات الأصول", assetMaintenanceOrders: "أوامر صيانة الأصول",
};
function permissionsForProfile(profile) {
  const actions = actionPermissions(profile);
  if (isAdministrativeRole(profile?.role)) return {
    pages: ALL_PAGE_IDS,
    can_delete: true,
    view_financials: true,
    can_create_products: true,
    can_edit_products: true, ...actions,
  };
  if (profile?.role === "production") {
    const hasSavedPages = Array.isArray(profile?.permissions?.pages);
    const savedPages = hasSavedPages ? profile.permissions.pages.filter((page) => PRODUCTION_ALLOWED_PAGES.includes(page)) : ["projects", "production"];
    return {
      pages: [...new Set(["projects", ...savedPages])],
      can_delete: false,
      view_financials: false,
      can_create_products: false,
      can_edit_products: false,
      ...actions,
    };
  }
  const saved = profile?.permissions || {};
  const isAccountant = profile?.role === "accountant";
  const legacyPages = (Array.isArray(saved.pages) ? saved.pages : (NAV_BY_ROLE[profile?.role] || [])).filter((page) => page !== "settings");
  const modulePages = [actions.projects_view && "projects", actions.project_files_view && "projectFiles", actions.assets_view && "assets", actions.payroll_calendar_view && "workCalendar", actions.payroll_view && "payroll", actions.daily_labor_view && "dailyLabor"].filter(Boolean);
  if (actions.audit_log_view) modulePages.push("auditLog");
  return {
    pages: [...new Set([...legacyPages, ...modulePages])],
    can_delete: Boolean(saved.can_delete),
    view_financials: Boolean(saved.view_financials),
    can_create_products: saved.can_create_products ?? isAccountant,
    can_edit_products: Boolean(saved.can_edit_products), ...actions,
  };
}
const MATERIAL_UNITS = ["قطعة", "متر", "متر مربع", "متر مكعب", "كيلوجرام", "جرام", "لتر", "مللي لتر", "لفة", "طقم", "علبة", "كرتونة", "أخرى"];

const PAGE_DESCRIPTIONS = {
  dashboard: "ملخص تنفيذي لأهم مؤشرات العمل والتنبيهات والأنشطة الحديثة.",
  projects: "متابعة المشاريع ونسب الإنجاز والعملاء والملفات المرتبطة.",
  projectFiles: "الوصول المنظم إلى مستندات المشاريع ومرفقاتها.",
  inventory: "رؤية فورية لأرصدة الخامات والمنتجات وحالات النقص.",
  purchases: "تسجيل ومراجعة مشتريات التشغيل وتكاليف التوريد.",
  expenses: "إدارة المصروفات وتصنيفها ومتابعة أثرها المالي.",
  materials: "تعريف الخامات ومتابعة التكلفة والرصيد المتاح.",
  products: "إدارة المنتجات ومكونات التصنيع والتكلفة التقديرية.",
  production: "تخطيط أوامر الإنتاج ومتابعة التنفيذ والكميات.",
  assets: "إدارة الأصول والعِدّة والعهد والإرجاعات وسجل الحركة.",
  sales: "تسجيل المبيعات ومتابعة حركة المنتجات والعملاء.",
  rentals: "إدارة عمليات الإيجار وحالة الوحدات المستأجرة.",
  suppliers: "متابعة الموردين والمستحقات والمدفوعات.",
  customers: "إدارة بيانات العملاء والأرصدة والتحصيلات.",
  employees: "إدارة فريق العمل والبيانات الوظيفية.",
  workCalendar: "إدارة أسبوع العمل والورديات والعطلات بإصدارات تاريخية قابلة للتدقيق.",
  payroll: "إعداد الرواتب ومراجعتها واعتماد دورة الصرف.",
  dailyLabor: "تسجيل العمالة اليومية والتكلفة والحضور.",
  reports: "تحليل الأداء المالي والتشغيلي لاتخاذ قرارات أوضح.",
  auditLog: "تتبع العمليات والتغييرات الحساسة داخل النظام.",
  team: "إدارة المستخدمين والأدوار والصلاحيات بأمان.",
  settings: "إعدادات الإدارة وأدوات الاسترداد الآمن للحسابات.",
};

const fetchTableRows = createTableFetcher({
  supabase,
  withTimeout,
  projectFilesTable: TABLES.projectFiles,
  pageLabels: PAGE_LABELS,
  logger: console,
});

/* ------------------------------ دوال الحسابات ------------------------------ */
function bomUnitCost(product, data) {
  return (product.bom || []).reduce((s, r) => {
    const m = data.materials.find((x) => x.id === r.material_id);
    return s + (m ? m.unit_cost * r.qty : 0);
  }, 0);
}
function productUnitCost(product, data) {
  return bomUnitCost(product, data) + num(product.labor_cost) + num(product.overhead_cost);
}
function producedQty(productId, data) {
  return data.productionOrders.filter((o) => o.product_id === productId).reduce((s, o) => s + o.qty, 0);
}
function soldQty(productId, data) {
  return data.sales.filter((s) => s.product_id === productId && s.status !== "cancelled").reduce((s, o) => s + o.qty, 0);
}
function activeRentedQty(productId, data) {
  return data.rentals.filter((r) => r.product_id === productId && r.status === "active").reduce((s, r) => s + r.qty, 0);
}
function finishedStock(productId, data) { return producedQty(productId, data) - soldQty(productId, data) - activeRentedQty(productId, data); }
function avgProductionUnitCost(productId, data) {
  const os = data.productionOrders.filter((o) => o.product_id === productId);
  const q = os.reduce((s, o) => s + o.qty, 0);
  const c = os.reduce((s, o) => s + o.total_cost, 0);
  return q > 0 ? c / q : 0;
}
function supplierPurchaseTotal(supplierId, data) {
  return data.materialPurchases.filter((p) => p.supplier_id === supplierId).reduce((s, p) => s + p.qty * p.unit_cost, 0);
}
function supplierPaymentTotal(supplierId, data) {
  return supplierBalances(supplierId, data).cashPaid;
}
function supplierBalance(supplierId, data) { return supplierBalances(supplierId, data).due; }
function customerSaleTotal(customerId, data) {
  return data.sales.filter((s) => s.customer_id === customerId && s.status !== "cancelled").reduce((s, o) => s + o.total, 0);
}
function customerReceiptTotal(customerId, data) {
  return customerBalances(customerId, data).cashReceived;
}
function customerRentalTotal(customerId, data) {
  return data.rentals.filter((r) => r.customer_id === customerId && r.status !== "cancelled").reduce((s, r) => s + r.rental_fee, 0);
}
function customerBalance(customerId, data) { return customerBalances(customerId, data).due; }

/* ------------------------------- عناصر عامة ------------------------------- */
function Card({ children, style, className = "", ...rest }) {
  return <div className={`legacy-card ${className}`} style={{ background: C.panel, border: `1px solid ${C.border}`, borderRadius: "var(--radius-lg)", boxShadow: "var(--shadow-sm)", padding: 18, ...style }} {...rest}>{children}</div>;
}
function Field({ label, children, style }) {
  return <label style={{ display: "flex", flexDirection: "column", gap: 6, fontSize: 13, color: C.muted, flex: 1, minWidth: 140, ...style }}>{label}{children}</label>;
}
const inputStyle = { background: C.bg, border: `1px solid ${C.border}`, borderRadius: 8, padding: "9px 11px", color: C.text, fontFamily: "Tajawal, sans-serif", fontSize: 14, outline: "none", width: "100%" };
function Input(props) { return <input {...props} style={{ ...inputStyle, ...(props.style || {}) }} />; }
function Select(props) { return <select {...props} style={{ ...inputStyle, ...(props.style || {}) }}>{props.children}</select>; }
function Btn({ children, variant = "primary", ...rest }) {
  const styles = {
    primary: { background: C.wood, color: "#fff" },
    ghost: { background: "transparent", color: C.text, border: `1px solid ${C.border}` },
    danger: { background: "var(--color-danger-soft)", color: C.red, border: "1px solid color-mix(in srgb, var(--color-danger) 25%, transparent)" },
  };
  return <button {...rest} disabled={rest.disabled} style={{ display: "inline-flex", alignItems: "center", gap: 6, border: "none", borderRadius: 8, padding: "9px 16px", fontFamily: "Tajawal, sans-serif", fontWeight: 700, fontSize: 13.5, cursor: rest.disabled ? "default" : "pointer", opacity: rest.disabled ? 0.6 : 1, ...styles[variant], ...(rest.style || {}) }}>{children}</button>;
}
function SectionTitle({ eyebrow, title, icon, description }) {
  const pageId = Object.keys(PAGE_LABELS).find((id) => PAGE_LABELS[id] === title);
  return (
    <header className="page-header">
      <div className="page-header-copy">
      <div className="page-eyebrow">
        {icon}<span>{eyebrow}</span>
      </div>
      <h2>{title}</h2>
      <p>{description || PAGE_DESCRIPTIONS[pageId] || "إدارة البيانات والعمليات المرتبطة بهذا القسم."}</p>
      </div>
    </header>
  );
}
function Banner({ type = "error", children }) {
  const isErr = type === "error";
  return (
    <div style={{ display: "flex", alignItems: "flex-start", gap: 8, background: isErr ? "var(--color-danger-soft)" : "var(--color-success-soft)", border: `1px solid ${isErr ? C.red : C.green}`, color: isErr ? C.red : C.green, borderRadius: 8, padding: "10px 12px", fontSize: 13, marginTop: 10 }}>
      {isErr ? <AlertCircle size={16} style={{ flexShrink: 0, marginTop: 2 }} /> : <CheckCircle2 size={16} style={{ flexShrink: 0, marginTop: 2 }} />}
      <span>{children}</span>
    </div>
  );
}
function Table({ headers, children }) {
  return (
    <div className="legacy-table-wrap" style={{ overflowX: "auto" }}>
      <table className="legacy-table" style={{ width: "100%", borderCollapse: "collapse", fontSize: 13.5 }}>
        <thead><tr>{headers.map((h, i) => <th key={i} style={{ textAlign: "right", color: C.muted, fontWeight: 700, padding: "8px 10px", borderBottom: `1px solid ${C.border}`, whiteSpace: "nowrap" }}>{h}</th>)}</tr></thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  );
}
function Td({ children, style, colSpan }) { return <td colSpan={colSpan} style={{ padding: "9px 10px", borderBottom: `1px solid ${C.border}`, color: C.text, ...style }}>{children}</td>; }
function Empty({ text }) { return <div style={{ color: C.muted, fontSize: 13.5, padding: "18px 4px", textAlign: "center" }}>{text}</div>; }
function SearchBox({ value, onChange, placeholder }) {
  return (
    <div style={{ marginBottom: 12 }}>
      <Input value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder || "بحث بالاسم..."} style={{ maxWidth: 280 }} />
    </div>
  );
}

/* ----------------------------- شاشة الدخول ----------------------------- */
function authErrorMessage(error) {
  const message = String(error?.message || error || "").toLowerCase();
  if (message.includes("invalid login credentials")) return "بيانات الدخول غير صحيحة. راجع رقم الهاتف أو البريد وكلمة السر.";
  if (message.includes("password") && message.includes("least")) return "كلمة السر أقصر من الحد المطلوب.";
  if (message.includes("failed to fetch") || message.includes("network") || message.includes("timeout")) return "تعذر الاتصال بالخادم. راجع الإنترنت وحاول مرة أخرى.";
  return error?.message || "تعذر إتمام العملية. حاول مرة أخرى.";
}

function AuthGate({ notice = "" }) {
  const [identifier, setIdentifier] = useState("");
  const [password, setPassword] = useState("");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit() {
    setErr("");
    if (!identifier.trim() || !password) return setErr("اكتب رقم الهاتف أو البريد وكلمة السر");
    const login = identifier.includes("@")
      ? { email: identifier.trim().toLowerCase(), password }
      : { phone: normalizeAccountPhone(identifier), password };
    if ("phone" in login && !login.phone) return setErr("اكتب رقم الهاتف بالصيغة الدولية، مثال: +9665XXXXXXXX");
    setBusy(true);
    try {
      const { error } = await supabase.auth.signInWithPassword(login);
      if (error) setErr(authErrorMessage(error));
    } catch (error) {
      setErr(authErrorMessage(error));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div dir="rtl" style={{ fontFamily: "Tajawal, sans-serif", background: C.bg, minHeight: "100vh", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", color: C.text, padding: 24 }}>
      <div style={{ marginBottom: 22 }}>
        <img src="/logo.png" alt="NEXTEP" style={{ width: 300, maxWidth: "82vw", height: 110, objectFit: "contain", display: "block" }} />
      </div>
      <Card style={{ width: 340 }}>
        <h2 style={{ margin: "0 0 16px", textAlign: "center" }}>تسجيل الدخول</h2>

        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          <Field label="رقم الهاتف أو البريد">
            <Input value={identifier} onChange={(e) => setIdentifier(e.target.value)} placeholder="+9665XXXXXXXX" autoComplete="username" />
          </Field>
          <Field label="كلمة السر">
            <Input type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" />
          </Field>
        </div>

        <div style={{ marginTop: 16 }}>
          <Btn onClick={submit} disabled={busy} style={{ width: "100%", justifyContent: "center" }}>
            {busy ? "..." : "دخول"}
          </Btn>
        </div>
        {err && <Banner type="error">{err}</Banner>}
        {notice && <Banner type="error">{notice}</Banner>}
      </Card>
      <div style={{ fontSize: 11.5, color: C.muted, marginTop: 16, maxWidth: 340, textAlign: "center" }}>
        الحسابات ينشئها مالك النظام أو مدير النظام فقط. تواصل مع المسؤول إذا لم يكن لديك حساب.
      </div>
    </div>
  );
}

function PasswordChangeGate({ profile, onComplete, onSignOut }) {
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [message, setMessage] = useState({ type: "", text: "" });
  const [busy, setBusy] = useState(false);

  async function submit() {
    setMessage({ type: "", text: "" });
    if (password.length < 10) return setMessage({ type: "error", text: "كلمة السر الجديدة يجب ألا تقل عن 10 أحرف." });
    if (password !== confirmation) return setMessage({ type: "error", text: "تأكيد كلمة السر غير مطابق." });
    setBusy(true);
    const completionResult = await supabase.functions.invoke("admin-manage-user", { body: { action: "change_password", new_password: password } });
    if (completionResult.error || !completionResult.data?.ok) {
      setBusy(false);
      return setMessage({ type: "error", text: completionResult.data?.error || authErrorMessage(completionResult.error) });
    }
    await onComplete();
    setBusy(false);
  }

  return <div dir="rtl" style={{ fontFamily: "Tajawal, sans-serif", background: C.bg, minHeight: "100vh", display: "grid", placeItems: "center", color: C.text, padding: 24 }}>
    <Card style={{ width: 390, maxWidth: "100%" }}>
      <h2 style={{ marginTop: 0 }}>تغيير كلمة السر المؤقتة</h2>
      <p style={{ color: C.muted }}>مرحبًا {profile.full_name}. يلزم اختيار كلمة سر خاصة بك قبل فتح النظام.</p>
      <Field label="كلمة السر الجديدة"><Input type="password" value={password} onChange={(event) => setPassword(event.target.value)} autoComplete="new-password" /></Field>
      <Field label="تأكيد كلمة السر"><Input type="password" value={confirmation} onChange={(event) => setConfirmation(event.target.value)} autoComplete="new-password" /></Field>
      <div style={{ display: "flex", gap: 8, marginTop: 16 }}><Btn disabled={busy} onClick={submit}>{busy ? "جارِ الحفظ..." : "حفظ وفتح النظام"}</Btn><Btn variant="ghost" onClick={onSignOut}>تسجيل الخروج</Btn></div>
      {message.text && <Banner type={message.type}>{message.text}</Banner>}
    </Card>
  </div>;
}

/* --------------------------------- التطبيق --------------------------------- */
export default function App() {
  const { session, profile, status: bootstrapStatus, error: bootstrapError, notice: authNotice, fetchProfile, retry: retryBootstrap, signOut } = useProfileBootstrap({
    supabase, demo: V22_DEMO, demoProfile: ACTIVE_DEMO_PROFILE,
  });
  const [data, setData] = useState(V22_DEMO ? demoData : null);
  const initialLocation = readWorkspaceLocation(window.location.search);
  const [tab, setTab] = useState(V22_DEMO ? (ASSET_QR_MODE ? "assets" : initialLocation.page || "projects") : (ASSET_QR_MODE ? "assets" : initialLocation.page));
  const [routeProjectId, setRouteProjectId] = useState(initialLocation.projectId);
  const [dataWarnings, setDataWarnings] = useState([]);
  const [mutationFeedback, setMutationFeedback] = useState({ type: "success", message: "" });
  const [realtimeStatus, setRealtimeStatus] = useState(V22_DEMO ? (DEMO_CONNECTION_STATE === "offline" ? "RECONNECTING" : "DEMO") : "CONNECTING");
  const [openNavGroups, setOpenNavGroups] = useState(loadNavigationState);
  const [currencyLoadError, setCurrencyLoadError] = useState("");
  const [, setCurrencyRevision] = useState(0);

  useEffect(() => {
    if (V22_DEMO || !session || !profile) return;
    let active = true;
    void supabase.rpc("get_system_settings").then(({ data: settings, error }) => {
      if (!active) return;
      if (error) {
        console.error("[Currency] settings bootstrap failed", error);
        setCurrencyLoadError("تعذر تحميل العملة العامة؛ قد تظهر مبالغ بتنسيق محفوظ سابقًا حتى إعادة المحاولة.");
        return;
      }
      configureCurrency(settings || {});
      setCurrencyRevision((current) => current + 1);
      setCurrencyLoadError("");
    });
    return () => { active = false; };
  }, [session?.user?.id, profile?.id]);

  useEffect(() => {
    try {
      window.localStorage.setItem(NAV_GROUP_STORAGE_KEY, JSON.stringify(openNavGroups));
    } catch (error) {
      console.warn("[Navigation] Could not persist sidebar state", error);
    }
  }, [openNavGroups]);

  useEffect(() => {
    const onPopState = () => {
      const location = readWorkspaceLocation(window.location.search);
      setTab(location.page);
      setRouteProjectId(location.projectId);
    };
    window.addEventListener("popstate", onPopState);
    return () => window.removeEventListener("popstate", onPopState);
  }, []);

  const selectedGroupId = useMemo(() => NAV_GROUPS.find((group) => group.pages.includes(tab))?.id, [tab]);
  useEffect(() => {
    if (!selectedGroupId) return;
    setOpenNavGroups((current) => current[selectedGroupId] === false ? { ...current, [selectedGroupId]: true } : current);
  }, [selectedGroupId]);

  useEffect(() => {
    if (V22_DEMO) return;
    if (session === undefined) return;
    if (!session) { setData(null); return; }
    setData(null);
  }, [session?.user?.id]);

  const refetchTable = useCallback(async (key) => {
    if (V22_DEMO) return;
    const table = TABLES[key];
    const fetchResult = await fetchTableRows(key, table);
    if (!fetchResult.error) {
      setData((prev) => ({ ...(prev || EMPTY_DATA), [key]: fetchResult.data || [] }));
      setDataWarnings((current) => current.filter((item) => item !== key));
    } else {
      setDataWarnings((current) => current.includes(key) ? current : [...current, key]);
    }
    return fetchResult;
  }, []);

  useEffect(() => {
    if (V22_DEMO) return;
    if (!session || !profile) return;
    let disposed = false;
    let reconnectTimer = null;
    let reconnectAttempt = 0;
    let connectGeneration = 0;
    let synchronizedGeneration = 0;
    let channels = [];
    const channelStatuses = { data: "CONNECTING", profile: "CONNECTING" };
    const tableRefreshState = new Map();
    const activeTableKeys = dataTableKeysForRole(profile.role, Boolean(profile.permissions?.assets_view));
    const activeTableEntries = Object.entries(TABLES).filter(([key]) => activeTableKeys.includes(key));

    (async () => {
      const results = await Promise.all(
        activeTableEntries.map(async ([key, table]) => {
          const fetchResult = await fetchTableRows(key, table);
          return { key, fetchResult };
        })
      );
      if (!disposed) {
        setData({ ...EMPTY_DATA, ...Object.fromEntries(results.map(({ key, fetchResult }) => [key, fetchResult.error ? [] : (fetchResult.data || [])])) });
        setDataWarnings(results.filter(({ fetchResult }) => fetchResult.error).map(({ key }) => key));
      }
    })();

    const updateConnectionStatus = (channelName, status) => {
      channelStatuses[channelName] = status;
      const combined = nextRealtimeState(channelStatuses);
      setRealtimeStatus(combined);
      console.info(`[Realtime:${channelName}] ${status}`, { combined });
      if (combined === "CONNECTED") {
        reconnectAttempt = 0;
        if (synchronizedGeneration !== connectGeneration) {
          synchronizedGeneration = connectGeneration;
          console.info("[Realtime] connected; reconciling missed changes");
          void Promise.all([
            ...activeTableKeys.map((key) => refetchTable(key)),
            fetchProfile(session.user.id, { background: true }),
          ]);
        }
      }
      if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") scheduleReconnect();
    };

    const removeChannels = async () => {
      const staleChannels = channels;
      channels = [];
      await Promise.all(staleChannels.map((channel) => supabase.removeChannel(channel)));
    };

    const requestTableRefresh = (key) => {
      const state = tableRefreshState.get(key) || { running: false, queued: false };
      if (state.running) {
        state.queued = true;
        tableRefreshState.set(key, state);
        return;
      }
      state.running = true;
      tableRefreshState.set(key, state);
      void (async () => {
        try {
          do {
            state.queued = false;
            await refetchTable(key);
          } while (!disposed && state.queued);
        } catch (error) {
          console.error("[Realtime] table reconciliation failed", { key, error });
        } finally {
          state.running = false;
        }
      })();
    };

    const connect = async () => {
      if (disposed) return;
      const generation = ++connectGeneration;
      await removeChannels();
      if (disposed || generation !== connectGeneration) return;
      channelStatuses.data = "CONNECTING";
      channelStatuses.profile = "CONNECTING";
      setRealtimeStatus("CONNECTING");

      const dataChannel = supabase.channel(`factory-data-${session.user.id}`);
      buildRealtimeChannelPlan({
        role: profile.role,
        dataKeys: [
          ...activeTableKeys,
          ...(activeTableKeys.includes("assets") ? ["assetRealtimeSignal"] : []),
          ...(activeTableKeys.includes("projects") ? ["projectRealtimeSignal"] : []),
        ],
      }).forEach(({ table, key, event, schema }) => {
        dataChannel.on("postgres_changes", { event, schema, table }, (payload) => {
          if (disposed || generation !== connectGeneration) return;
          console.info("[Realtime:data] postgres_changes", { table, key, event: payload.eventType });
          if (key === "assetRealtimeSignal") {
            requestTableRefresh("assets");
            if (activeTableKeys.includes("assetAlerts")) requestTableRefresh("assetAlerts");
            return;
          }
          if (key === "projectRealtimeSignal") {
            requestTableRefresh("projects");
            return;
          }
          requestTableRefresh(key);
          if (key.startsWith("asset")) {
            if (key !== "assets" && activeTableKeys.includes("assets")) requestTableRefresh("assets");
            if (activeTableKeys.includes("assetAlerts")) requestTableRefresh("assetAlerts");
          }
        });
      });

      const profileChannel = supabase
        .channel(`factory-profile-${session.user.id}`)
        .on(
          "postgres_changes",
          { event: "*", schema: "public", table: "profiles", filter: `id=eq.${session.user.id}` },
          async (payload) => {
            if (disposed || generation !== connectGeneration) return;
            console.info("[Realtime:profile] postgres_changes", { event: payload.eventType, userId: session.user.id });
            if (payload.eventType === "DELETE") {
              await signOut("تم حذف أو تعطيل حسابك. تواصل مع مدير النظام.");
              return;
            }
            await fetchProfile(session.user.id, { background: true });
          }
        );

      channels = [dataChannel, profileChannel];
      dataChannel.subscribe((status) => { if (generation === connectGeneration) updateConnectionStatus("data", status); });
      profileChannel.subscribe((status) => { if (generation === connectGeneration) updateConnectionStatus("profile", status); });
    };

    function scheduleReconnect() {
      if (disposed || reconnectTimer) return;
      const delay = Math.min(1000 * (2 ** reconnectAttempt), 30000);
      reconnectAttempt += 1;
      console.warn("[Realtime] reconnect scheduled", { delay, reconnectAttempt });
      setRealtimeStatus("RECONNECTING");
      reconnectTimer = window.setTimeout(() => {
        reconnectTimer = null;
        void connect();
      }, delay);
    }

    const handleOnline = () => {
      console.info("[Realtime] browser is online; reconnecting");
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      reconnectTimer = null;
      void connect();
    };

    void connect();
    window.addEventListener("online", handleOnline);
    return () => {
      disposed = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      window.removeEventListener("online", handleOnline);
      connectGeneration += 1;
      void removeChannels();
    };
  }, [session?.user?.id, profile?.role, refetchTable, fetchProfile, signOut]);

  const permissions = useMemo(() => profile ? permissionsForProfile(profile) : null, [profile]);
  useEffect(() => {
    if (!permissions) return;
    setTab((currentTab) => resolveAllowedTab(currentTab, permissions.pages || []));
  }, [permissions]);

  const navigate = useCallback((page, options = {}) => {
    const next = { page, projectId: options.projectId || null };
    const nextUrl = workspaceUrl(next);
    if (options.replace) window.history.replaceState(next, "", nextUrl);
    else window.history.pushState(next, "", nextUrl);
    setTab(page);
    setRouteProjectId(next.projectId);
  }, []);

  if (ASSET_CONFIRMATION_MODE) return <AssetExternalConfirmation/>;
  if (V22_DEMO && DEMO_ACCOUNT_STATE === "missing") return <BootstrapFailure missingProfile message="تم تسجيل الدخول، لكن ملف الحساب الإداري غير موجود." session={{ user: { id: "00000000-0000-0000-0000-000000000099", email: "missing-profile@nextep.demo" } }} onRetry={() => {}} onSignOut={() => {}}/>;
  if (bootstrapStatus === "checking-session" || bootstrapStatus === "loading-profile") return <BootstrapLoading text={bootstrapStatus === "loading-profile" ? "جارِ تحميل بيانات حسابك..." : "جارِ التحقق من الجلسة..."}/>;
  if (bootstrapStatus === "error") return <BootstrapFailure message={bootstrapError} session={session} onRetry={retryBootstrap} onSignOut={() => signOut()}/>;
  if (bootstrapStatus === "missing-profile") return <BootstrapFailure missingProfile message={bootstrapError} session={session} onRetry={retryBootstrap} onSignOut={() => signOut()}/>;
  if (!session) return <AuthGate notice={authNotice} />;
  if (!profile) return <BootstrapFailure message="تعذر تحديد حالة الحساب." session={session} onRetry={retryBootstrap} onSignOut={() => signOut()}/>;
  if (profile.must_change_password) return <PasswordChangeGate profile={profile} onComplete={() => fetchProfile(session.user.id)} onSignOut={() => signOut()} />;
  if (!data) return <BootstrapLoading text="جارِ تحميل بيانات مساحة العمل..." />;

  const role = profile.role;
  const activeTab = resolveAllowedTab(tab, permissions.pages);
  const ALL_NAV = [
    { id: "dashboard", label: "لوحة التحكم", icon: LayoutDashboard },
    { id: "projects", label: "المشاريع", icon: BriefcaseBusiness },
    { id: "projectFiles", label: "ملفات المشاريع", icon: FolderOpen },
    { id: "inventory", label: "المخزون", icon: Boxes },
    { id: "purchases", label: "المشتريات", icon: ClipboardList },
    { id: "expenses", label: "المصروفات", icon: ReceiptText },
    { id: "materials", label: "المواد الخام", icon: Package },
    { id: "products", label: "المنتجات والتكلفة", icon: Layers },
    { id: "production", label: "أوامر الإنتاج", icon: Factory },
    { id: "assets", label: "الأصول والعِدّة", icon: Wrench },
    { id: "sales", label: "المبيعات", icon: ShoppingCart },
    { id: "rentals", label: "الإيجارات", icon: CalendarClock },
    { id: "suppliers", label: "الموردين", icon: Truck },
    { id: "customers", label: "العملاء", icon: Users },
    { id: "employees", label: "الموظفون", icon: UserRoundCog },
    { id: "workCalendar", label: "تقويم العمل والعطلات", icon: CalendarClock },
    { id: "payroll", label: "المرتبات", icon: BadgeDollarSign },
    { id: "dailyLabor", label: "العمالة اليومية", icon: HardHat },
    { id: "reports", label: "التقارير", icon: BarChart3 },
    { id: "auditLog", label: "سجل التدقيق", icon: ScrollText },
    { id: "team", label: "الفريق والصلاحيات", icon: ShieldCheck },
    { id: "settings", label: "الإعدادات", icon: Settings },
  ];
  const NAV = ALL_NAV.filter((n) => permissions.pages.includes(n.id));
  const navigationGroups = buildNavigationGroups(NAV, permissions.pages);
  const activeGroup = navigationGroups.find((group) => group.items.some((item) => item.id === activeTab));
  const activePage = NAV.find((item) => item.id === activeTab);

  async function insertRow(key, payload) {
    const mutationResult = await supabase.from(TABLES[key]).insert(payload);
    const result = await syncMutation({ scope: `${key}:create`, mutationResult, refetch: () => refetchTable(key) });
    setMutationFeedback(result.error ? { type: "error", message: result.error.message } : result.refreshError ? { type: "warning", message: "تم الحفظ، لكن تعذر تحديث الشاشة. أعد تحميل البيانات دون تكرار العملية." } : { type: "success", message: "تم الحفظ بنجاح" });
    return result.error?.message || null;
  }
  async function deleteRow(key, id) {
    const mutationResult = await supabase.from(TABLES[key]).delete().eq("id", id);
    const result = await syncMutation({ scope: `${key}:delete`, mutationResult, refetch: () => refetchTable(key) });
    setMutationFeedback(result.error ? { type: "error", message: result.error.message } : result.refreshError ? { type: "warning", message: "تم الحذف، لكن تعذر تحديث الشاشة." } : { type: "success", message: "تم الحذف بنجاح" });
    return result.error?.message || null;
  }
  async function updateRow(key, id, patch) {
    const mutationResult = await supabase.from(TABLES[key]).update(patch).eq("id", id);
    const result = await syncMutation({ scope: `${key}:update`, mutationResult, refetch: () => refetchTable(key) });
    setMutationFeedback(result.error ? { type: "error", message: result.error.message } : result.refreshError ? { type: "warning", message: "تم حفظ التعديل، لكن تعذر تحديث الشاشة." } : { type: "success", message: "تم حفظ التعديل بنجاح" });
    return result.error?.message || null;
  }

  const retryVisibleData = () => Promise.all(dataTableKeysForRole(role, Boolean(permissions.assets_view)).map((key) => refetchTable(key)));

  return (
    <AppShell navigationGroups={navigationGroups} openGroups={openNavGroups} setOpenGroups={setOpenNavGroups} activeGroup={activeGroup} activePage={activePage} activeTab={activeTab} profile={profile} roleLabel={ROLES[role]?.label} realtimeStatus={realtimeStatus} warnings={dataWarnings} onNavigate={navigate} onRetryData={retryVisibleData} onSignOut={() => signOut()}>
        {!activeTab && <div className="module-state no-permission"><ShieldCheck size={30}/><strong>لا توجد صلاحية للوصول</strong><p>لا توجد صفحات مسموحة لهذا الحساب حاليًا. تواصل مع مدير النظام لتحديث صلاحياتك.</p></div>}
        {dataWarnings.length > 0 && <div className="module-state error compact"><AlertCircle size={20}/><div><strong>تعذر تحديث بعض البيانات</strong><p>{dataWarnings.map((key) => PAGE_LABELS[key] || key).join("، ")} — قد تكون البيانات المعروضة غير مكتملة.</p></div><button type="button" onClick={retryVisibleData}>إعادة المحاولة</button></div>}
        {currencyLoadError && <div className="module-state error compact"><AlertCircle size={20}/><div><strong>إعداد العملة غير متزامن</strong><p>{currencyLoadError}</p></div></div>}
        {!["CONNECTED", "DEMO"].includes(realtimeStatus) && <div className="module-state offline compact"><AlertCircle size={20}/><div><strong>{realtimeStatus === "RECONNECTING" ? "جارِ إعادة الاتصال" : "الاتصال اللحظي غير جاهز"}</strong><p>يمكنك متابعة القراءة، وستتم مزامنة التغييرات تلقائيًا عند عودة الاتصال.</p></div><button type="button" onClick={retryVisibleData}>المحاولة الآن</button></div>}
        {activeTab === "dashboard" && <Dashboard data={data} navigate={navigate} permissions={permissions} />}
        {activeTab === "projects" && <ProjectsTab data={data} profile={profile} permissions={permissions} refresh={refetchTable} initialProjectId={routeProjectId} onProjectRoute={(projectId) => navigate("projects", { projectId, replace: !projectId })} />}
        {activeTab === "projectFiles" && <ProjectFilesHub data={data} permissions={permissions} refresh={refetchTable} />}
        {activeTab === "inventory" && <InventoryTab canViewFinancials={permissions.view_financials} onNavigate={navigate} allowedPages={permissions.pages || []} />}
        {activeTab === "purchases" && <ProcurementWorkspace data={data} onNavigate={navigate} />}
        {activeTab === "expenses" && <ExpensesTab data={data} insertRow={insertRow} profileRole={role} refresh={() => refetchTable("expenses")} />}
        {activeTab === "materials" && <MaterialsTab data={data} canDelete={permissions.can_delete} insertRow={insertRow} deleteRow={deleteRow} updateRow={updateRow} onNavigate={navigate} />}
        {activeTab === "products" && <ProductsTab data={data} canCreate={permissions.can_create_products} canEdit={permissions.can_edit_products} canArchive={permissions.can_delete && permissions.can_edit_products} hideProfitInfo={!permissions.view_financials} insertRow={insertRow} updateRow={updateRow} />}
        {activeTab === "production" && <ProductionTab data={data} profileRole={role} canViewFinancials={permissions.view_financials} />}
        {activeTab === "assets" && permissions.assets_view && <AssetsPage data={data} profile={profile} permissions={permissions} refresh={refetchTable} />}
        {activeTab === "sales" && <SalesTab data={data} insertRow={insertRow} refresh={() => refetchTable("sales")} canManage={isAdministrativeRole(role)} />}
        {activeTab === "rentals" && <RentalsTab data={data} insertRow={insertRow} refresh={() => refetchTable("rentals")} canManage={isAdministrativeRole(role)} />}
        {activeTab === "suppliers" && <SuppliersTab data={data} insertRow={insertRow} updateRow={updateRow} refresh={() => refetchTable("supplierPayments")} canManage={isAdministrativeRole(role)} />}
        {activeTab === "customers" && <CustomersTab data={data} insertRow={insertRow} updateRow={updateRow} refresh={() => refetchTable("customerReceipts")} canManage={isAdministrativeRole(role)} />}
        {activeTab === "employees" && role !== "production" && <EmployeesTab data={data} profile={profile} refresh={refetchTable} />}
        {activeTab === "workCalendar" && permissions.payroll_calendar_view && <WorkCalendarTab data={data} profile={profile} permissions={permissions} refresh={refetchTable} />}
        {activeTab === "payroll" && permissions.payroll_view && data.payroll.some((row) => row.status === "draft" && row.calendar_stale) && <div className="module-state error compact"><AlertCircle size={20}/><div><strong>مسودة الراتب تحتاج إعادة حساب</strong><p>تغير تقويم العمل بعد إنشاء المسودة. تمنع قاعدة البيانات اعتمادها حتى إعادة الحساب أو استخدام صلاحية التجاوز الموثقة.</p></div></div>}
        {activeTab === "payroll" && permissions.payroll_view && <PayrollTab data={data} profile={profile} permissions={permissions} refresh={refetchTable} />}
        {activeTab === "dailyLabor" && permissions.daily_labor_view && <DailyLaborTab data={data} profile={profile} permissions={permissions} refresh={refetchTable} />}
        {activeTab === "reports" && permissions.view_financials && <ReportsTab data={data} />}
        {activeTab === "auditLog" && permissions.audit_log_view && <AuditLogTab data={data} />}
        {activeTab === "team" && <TeamTab profiles={data.profiles} employees={data.employees} refresh={refetchTable} currentProfile={profile} />}
        {activeTab === "settings" && <SettingsPage currentProfile={profile} onRepaired={() => refetchTable("profiles")} onCurrencySaved={(settings) => { configureCurrency(settings); setCurrencyRevision((current) => current + 1); setCurrencyLoadError(""); }} />}
      <Toast type={mutationFeedback.type} message={mutationFeedback.message} onDismiss={() => setMutationFeedback((current) => ({ ...current, message: "" }))} />
    </AppShell>
  );
}

/* --------------------------------- Dashboard -------------------------------- */
function DashboardMetric({ label, value, tone = "wood" }) {
  return <div className={`dashboard-metric ${tone}`}><span>{label}</span><strong>{value}</strong></div>;
}

function DashboardSection({ title, description, action, children, className = "" }) {
  return <section className={`dashboard-section ${className}`}>
    <div className="dashboard-section-head"><div><h3>{title}</h3><p>{description}</p></div>{action}</div>
    <div className="dashboard-metrics">{children}</div>
  </section>;
}

function Dashboard({ data, navigate, permissions }) {
  const [inventoryWorkspace, setInventoryWorkspace] = useState(null);
  const [inventoryError, setInventoryError] = useState("");
  const [inventoryUpdatedAt, setInventoryUpdatedAt] = useState(null);
  useEffect(() => {
    let active = true;
    const loadInventory = () => supabase.rpc("get_inventory_workspace").then(({ data: workspace, error }) => {
      if (!active) return;
      if (error) setInventoryError("تعذر تحميل رصيد دفتر المخزون؛ لم يتم عرض تقدير بديل.");
      else { setInventoryWorkspace(workspace || {}); setInventoryError(""); setInventoryUpdatedAt(new Date()); }
    });
    void loadInventory();
    const channel = supabase.channel("dashboard-inventory-ledger")
      .on("postgres_changes", { event:"*", schema:"public", table:"inventory_movements" }, loadInventory)
      .subscribe();
    return () => { active = false; void supabase.removeChannel(channel); };
  }, [data.materials, data.materialPurchases, data.productionOrders]);

  const stats = useMemo(() => {
    const today = todayStr();
    const monthKey = today.slice(0, 7);
    const activeProjects = data.projects.filter((project) => !["delivered", "cancelled"].includes(project.status));
    const delayedProjects = activeProjects.filter((project) => project.delivery_date && project.delivery_date < today);
    const averageProgress = activeProjects.length ? activeProjects.reduce((sum, project) => sum + num(project.progress), 0) / activeProjects.length : 0;
    const materialAlerts = inventoryWorkspace ? canonicalMaterialAlerts(inventoryWorkspace) : { low: [], unlinked: [] };
    const lowMaterials = materialAlerts.low;
    const lowProducts = data.products.filter((product) => !product.archived_at).map((product) => ({ ...product, stock: finishedStock(product.id, data) })).filter((product) => product.stock <= 5).sort((a, b) => a.stock - b.stock);
    const postedSales = data.sales.filter((sale) => sale.status !== "cancelled");
    const revenue = postedSales.reduce((sum, sale) => sum + num(sale.total), 0);
    const cogs = postedSales.reduce((sum, sale) => {
      const product = data.products.find((row) => row.id === sale.product_id);
      return sum + (product ? num(sale.qty) * (avgProductionUnitCost(product.id, data) || productUnitCost(product, data)) : 0);
    }, 0);
    return {
      activeProjects: activeProjects.length,
      delayedProjects: delayedProjects.length,
      averageProgress,
      ordersThisMonth: data.productionOrders.filter((order) => (order.order_date || "").slice(0, 7) === monthKey).length,
      todayProduction: data.productionOrders.filter((order) => order.order_date === today).reduce((sum, order) => sum + num(order.qty), 0),
      lowMaterials, unlinkedMaterials: materialAlerts.unlinked,
      lowProducts,
      todaySales: postedSales.filter((sale) => sale.sale_date === today).reduce((sum, sale) => sum + num(sale.total), 0),
      profit: revenue - cogs,
      receivables: data.customers.reduce((sum, customer) => sum + customerBalance(customer.id, data), 0),
      activeEmployees: data.employees.filter((employee) => !["inactive", "suspended"].includes(employee.status)).length,
      pendingPayroll: data.payroll.filter((row) => row.status !== "paid").length,
      todayLabor: data.dailyLabor.filter((row) => row.work_date === today).length,
      activeAssetAssignments: data.assetAssignments.filter((row) => ["pending_receiver_confirmation", "issued", "partially_returned", "settlement_pending"].includes(row.status)).length,
      assetAlertCount: data.assetAlerts.length,
    };
  }, [data, inventoryWorkspace]);

  const recentActivities = [...data.projectActivities].sort((a, b) => String(b.created_at || "").localeCompare(String(a.created_at || ""))).slice(0, 6);
  const canGo = (page) => permissions.pages.includes(page);
  const quickAction = (page, label) => canGo(page) ? <button className="section-link" onClick={() => navigate(page)}>{label}</button> : null;

  return <div>
    <SectionTitle eyebrow="مركز العمل" title="لوحة التحكم" icon={<LayoutDashboard size={14} />} description="المعلومات الأهم مرتبة حسب أقسام العمل لتصل إلى القرار والإجراء بسرعة." />
    <div className="dashboard-layout">
      <DashboardSection title="المشاريع" description="التقدم والمواعيد والمخاطر الحالية" action={quickAction("projects", "فتح المشاريع")}>
        <DashboardMetric label="مشاريع نشطة" value={stats.activeProjects} />
        <DashboardMetric label="متوسط الإنجاز" value={`${Math.round(stats.averageProgress)}%`} tone="gold" />
        <DashboardMetric label="مشاريع متأخرة" value={stats.delayedProjects} tone={stats.delayedProjects ? "danger" : "success"} />
      </DashboardSection>

      <DashboardSection title="التشغيل والإنتاج" description="حركة الإنتاج وحالة المخزون" action={quickAction("production", "فتح الإنتاج")}>
        <DashboardMetric label="إنتاج اليوم" value={`${fmt(stats.todayProduction)} وحدة`} tone="info" />
        <DashboardMetric label="أوامر هذا الشهر" value={stats.ordersThisMonth} />
        <DashboardMetric label="أصناف منخفضة" value={stats.lowMaterials.length + stats.lowProducts.length} tone={(stats.lowMaterials.length + stats.lowProducts.length) ? "warning" : "success"} />
        {canGo("assets") && <DashboardMetric label="عهد أصول نشطة" value={stats.activeAssetAssignments} tone={stats.activeAssetAssignments ? "info" : "success"} />}
      </DashboardSection>

      {permissions.view_financials && <DashboardSection title="المالية" description="السيولة والربحية والتحصيلات" action={quickAction("reports", "فتح التقارير")}>
        <DashboardMetric label="مبيعات اليوم" value={formatMoney(stats.todaySales)} tone="success" />
        <DashboardMetric label="صافي الربح التقديري" value={formatMoney(stats.profit)} tone={stats.profit >= 0 ? "success" : "danger"} />
        <DashboardMetric label="مستحق من العملاء" value={formatMoney(stats.receivables)} tone="gold" />
      </DashboardSection>}

      {canGo("employees") && <DashboardSection title="الموارد البشرية" description="القوة العاملة ودورة الرواتب" action={quickAction("employees", "فتح الموظفين")}>
        <DashboardMetric label="موظفون نشطون" value={stats.activeEmployees} />
        <DashboardMetric label="رواتب قيد الإجراء" value={stats.pendingPayroll} tone={stats.pendingPayroll ? "warning" : "success"} />
        <DashboardMetric label="عمالة اليوم" value={stats.todayLabor} tone="info" />
      </DashboardSection>}

      <DashboardSection title="التنبيهات" description="العناصر التي تحتاج تدخلاً سريعًا" className="dashboard-wide" action={quickAction("inventory", "فتح المخزون")}>
        <div className="dashboard-alerts">
          {inventoryUpdatedAt && <div className="dashboard-clear"><CheckCircle2 size={18}/> المصدر: دفتر حركات المخزون · آخر تحديث {inventoryUpdatedAt.toLocaleTimeString("ar-EG")}</div>}
          {stats.lowMaterials.slice(0, 3).map((item) => <div className="dashboard-alert" key={`material-${item.id}`}><AlertCircle size={17} /><span><strong>{item.name}</strong> — الرصيد {fmt(item.quantityOnHand)} {item.unit} عبر {item.warehouseNames.length} مخزن</span></div>)}
          {stats.unlinkedMaterials.slice(0, 3).map((item) => <div className="dashboard-alert" key={`unlinked-material-${item.id}`}><AlertCircle size={17} /><span><strong>{item.name}</strong> — جودة بيانات: المادة غير مربوطة بصنف مخزون، ولا يوجد تقدير رصيد.</span></div>)}
          {inventoryError && <div className="dashboard-alert"><AlertCircle size={17}/><span>{inventoryError}</span></div>}
          {stats.lowProducts.slice(0, 3).map((item) => <div className="dashboard-alert" key={`product-${item.id}`}><AlertCircle size={17} /><span><strong>{item.name}</strong> — المتاح {fmt(item.stock)} وحدة</span></div>)}
          {stats.assetAlertCount > 0 && <div className="dashboard-alert"><AlertCircle size={17}/><span><strong>تنبيهات الأصول والعِدّة</strong> — {stats.assetAlertCount} عنصر يحتاج متابعة</span></div>}
          {!inventoryError && !stats.unlinkedMaterials.length && !stats.lowMaterials.length && !stats.lowProducts.length && !stats.assetAlertCount && <div className="dashboard-clear"><CheckCircle2 size={18} /> لا توجد تنبيهات مخزون أو أصول حرجة حاليًا.</div>}
        </div>
      </DashboardSection>

      <DashboardSection title="آخر الأنشطة" description="أحدث ما تم على المشاريع" className="dashboard-wide" action={quickAction("projects", "عرض الكل")}>
        <div className="dashboard-activity-list">
          {recentActivities.map((activity) => <div className="dashboard-activity" key={activity.id}><span className="activity-mark" /><div><strong>{activity.title || activity.activity_type || "نشاط مشروع"}</strong><small>{activity.description || new Date(activity.created_at).toLocaleString("ar-EG")}</small></div></div>)}
          {!recentActivities.length && <Empty text="لا توجد أنشطة مسجلة بعد." />}
        </div>
      </DashboardSection>
    </div>
  </div>;
}


/* -------------------------------- Inventory --------------------------------- */
const InventoryTab=InventoryWorkspace;

/* --------------------------------- Materials -------------------------------- */
const MaterialsTab=MaterialsCatalogWorkspace;

/* --------------------------------- Products --------------------------------- */
function ProductsTab({ data, canCreate, canEdit, canArchive, hideProfitInfo, insertRow, updateRow }) {
  const blank = { name: "", sku: "", laborCost: "", overheadCost: "", sellingPrice: "", itemType: "sale" };
  const [form, setForm] = useState(blank);
  const [bom, setBom] = useState([]);
  const [bomRow, setBomRow] = useState({ materialId: "", qty: "" });
  const [editingId, setEditingId] = useState(null);
  const [err, setErr] = useState("");
  const [search, setSearch] = useState("");

  function addBomRow() { if (!bomRow.materialId || num(bomRow.qty) <= 0) return; setBom([...bom, { material_id: bomRow.materialId, qty: num(bomRow.qty) }]); setBomRow({ materialId: "", qty: "" }); }
  function removeBomRow(i) { setBom(bom.filter((_, idx) => idx !== i)); }
  function startEdit(p) {
    if (!canEdit) return;
    setEditingId(p.id);
    setForm({ name: p.name, sku: p.sku || "", laborCost: String(p.labor_cost), overheadCost: String(p.overhead_cost), sellingPrice: String(p.selling_price), itemType: p.item_type || "sale" });
    setBom(p.bom || []);
  }
  function cancelEdit() { setEditingId(null); setForm(blank); setBom([]); setErr(""); }

  async function submitProduct() {
    if (editingId && !canEdit) return setErr("ليس لديك صلاحية تعديل المنتجات");
    if (!editingId && !canCreate) return setErr("ليس لديك صلاحية إضافة المنتجات");
    if (!form.name.trim()) return setErr("اكتب اسم المنتج");
    if (bom.length === 0) return setErr("أضف مكوّن واحد على الأقل لتركيبة المنتج");
    const payload = { name: form.name.trim(), sku: form.sku.trim(), bom, labor_cost: num(form.laborCost), overhead_cost: num(form.overheadCost), selling_price: num(form.sellingPrice), item_type: form.itemType };
    const e = editingId ? await updateRow("products", editingId, payload) : await insertRow("products", payload);
    if (e) return setErr(e);
    setForm(blank); setBom([]); setEditingId(null); setErr("");
  }
  async function archiveProduct(product) {
    const reason = window.prompt(`سبب أرشفة المنتج "${product.name}"؟`);
    if (!reason?.trim()) return;
    if (!window.confirm("سيُمنع المنتج من العمليات الجديدة مع الاحتفاظ بكل تاريخه. متابعة؟")) return;
    const error = await updateRow("products", product.id, { archived_at: new Date().toISOString(), archived_reason: reason.trim() });
    if (error) return setErr(error);
    if (editingId === product.id) cancelEdit();
    setErr("");
  }
  async function restoreProduct(product) {
    if (!window.confirm(`استعادة المنتج "${product.name}" للعمليات الجديدة؟`)) return;
    const error = await updateRow("products", product.id, { archived_at: null, archived_reason: null });
    if (error) setErr(error); else setErr("");
  }

  const activeProducts = data.products.filter((product) => !product.archived_at);
  const archivedProducts = data.products.filter((product) => product.archived_at);
  const matchesSearch = (product) => product.name.toLowerCase().includes(search.toLowerCase());
  const filtered = activeProducts.filter(matchesSearch);
  const filteredArchived = archivedProducts.filter(matchesSearch);
  const ITEM_TYPE_LABEL = { sale: "للبيع", rental: "للإيجار", both: "بيع وإيجار" };

  return (
    <div>
      <SectionTitle eyebrow="تكلفة المنتج" title="المنتجات وتركيبة التكلفة" icon={<Layers size={14} />} />
      {(canCreate || (editingId && canEdit)) && <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>{editingId ? "تعديل منتج" : "منتج جديد"}</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginBottom: 14 }}>
          <Field label="اسم المنتج"><Input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="مثال: طاولة زان كلاسيك" /></Field>
          <Field label="كود المنتج (SKU)"><Input value={form.sku} onChange={(e) => setForm({ ...form, sku: e.target.value })} /></Field>
          <Field label="النوع">
            <Select value={form.itemType} onChange={(e) => setForm({ ...form, itemType: e.target.value })}>
              <option value="sale">للبيع فقط</option>
              <option value="rental">للإيجار فقط</option>
              <option value="both">للبيع والإيجار</option>
            </Select>
          </Field>
          <Field label="تكلفة العمالة / وحدة"><Input type="number" value={form.laborCost} onChange={(e) => setForm({ ...form, laborCost: e.target.value })} /></Field>
          <Field label="التكاليف غير المباشرة / وحدة"><Input type="number" value={form.overheadCost} onChange={(e) => setForm({ ...form, overheadCost: e.target.value })} /></Field>
          {!hideProfitInfo && (
            <Field label="سعر البيع المقترح"><Input type="number" value={form.sellingPrice} onChange={(e) => setForm({ ...form, sellingPrice: e.target.value })} /></Field>
          )}
        </div>
        <div style={{ fontSize: 13, color: C.muted, marginBottom: 8, fontWeight: 700 }}>تركيبة المواد الخام (BOM) لكل وحدة واحدة من المنتج</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap", alignItems: "flex-end", marginBottom: 10 }}>
          <Field label="المادة"><Select value={bomRow.materialId} onChange={(e) => setBomRow({ ...bomRow, materialId: e.target.value })}><option value="">اختر مادة</option>{data.materials.map((m) => <option key={m.id} value={m.id}>{m.name} ({m.unit})</option>)}</Select></Field>
          <Field label="الكمية لكل وحدة"><Input type="number" value={bomRow.qty} onChange={(e) => setBomRow({ ...bomRow, qty: e.target.value })} /></Field>
          <Btn variant="ghost" onClick={addBomRow}><Plus size={15} /> إضافة للتركيبة</Btn>
        </div>
        {bom.length > 0 && (
          <div style={{ marginBottom: 12 }}>
            <Table headers={["المادة", "الكمية", "التكلفة", ""]}>
              {bom.map((r, i) => { const m = data.materials.find((x) => x.id === r.material_id); return (
                <tr key={i}><Td>{m?.name}</Td><Td>{r.qty} {m?.unit}</Td><Td>{formatMoney((m?.unit_cost || 0) * r.qty)}</Td>
                  <Td><button aria-label={`حذف ${m?.name||"المادة"} من التركيبة`} title="حذف من التركيبة" onClick={() => removeBomRow(i)} style={{ background: "none", border: "none", cursor: "pointer", color: C.red }}><Trash2 size={14} /></button></Td></tr>
              ); })}
            </Table>
          </div>
        )}
        <div style={{ display: "flex", gap: 8 }}>
          <Btn onClick={submitProduct}>{editingId ? <><Pencil size={15} /> حفظ التعديل</> : <><Plus size={15} /> حفظ المنتج</>}</Btn>
          {editingId && <Btn variant="ghost" onClick={cancelEdit}><X size={15} /> إلغاء</Btn>}
        </div>
        {err && <Banner>{err}</Banner>}
      </Card>}
      {!canCreate && !canEdit && <Banner>يمكنك عرض المنتجات فقط. تواصل مع المدير لإضافة صلاحية إنشاء أو تعديل المنتجات.</Banner>}
      <Card>
        <SearchBox value={search} onChange={setSearch} placeholder="ابحث باسم المنتج..." />
        {filtered.length === 0 ? <Empty text="لا توجد نتائج" /> : (
          <Table headers={["المنتج", "النوع", "تكلفة الخامات", "عمالة", "تكاليف غير مباشرة", "إجمالي التكلفة/وحدة", ...(hideProfitInfo ? [] : ["سعر البيع", "الهامش"]), "المخزون التام", ""]}>
            {filtered.map((p) => {
              const matCost = bomUnitCost(p, data);
              const unitCost = productUnitCost(p, data);
              const margin = p.selling_price > 0 ? ((p.selling_price - unitCost) / p.selling_price) * 100 : null;
              return (
                <tr key={p.id}>
                  <Td>{p.name}</Td>
                  <Td>{ITEM_TYPE_LABEL[p.item_type] || "للبيع"}</Td>
                  <Td>{formatMoney(matCost)}</Td><Td>{formatMoney(p.labor_cost)}</Td><Td>{formatMoney(p.overhead_cost)}</Td>
                  <Td style={{ fontWeight: 700, color: C.brass }}>{formatMoney(unitCost)}</Td>
                  {!hideProfitInfo && (<>
                    <Td>{formatMoney(p.selling_price)}</Td>
                    <Td style={{ color: margin == null ? C.muted : margin >= 0 ? C.green : C.red }}>{margin == null ? "—" : `${margin.toFixed(1)}%`}</Td>
                  </>)}
                  <Td>{finishedStock(p.id, data)}</Td>
                  <Td style={{ display: "flex", gap: 10 }}>
                    {canEdit && <button aria-label={`تعديل ${p.name}`} title="تعديل المنتج" onClick={() => startEdit(p)} style={{ background: "none", border: "none", cursor: "pointer", color: C.brass }}><Pencil size={15} /></button>}
                    {canArchive && <button aria-label={`أرشفة ${p.name}`} onClick={() => archiveProduct(p)} style={{ background: "none", border: "none", cursor: "pointer", color: C.red }}><Archive size={15} /></button>}
                  </Td>
                </tr>
              );
            })}
          </Table>
        )}
      </Card>
      <ArchiveSection title="المنتجات المؤرشفة" count={archivedProducts.length} helpText="محفوظة للتاريخ ولا تظهر في البيع أو الإيجار أو أوامر الإنتاج الجديدة.">
        {filteredArchived.length === 0 ? <Empty text="لا توجد منتجات مؤرشفة مطابقة" /> : <Table headers={["المنتج", "SKU", "النوع", "سبب الأرشفة", "تاريخ الأرشفة", ""]}>{filteredArchived.map((p) => <tr key={p.id}><Td>{p.name}</Td><Td>{p.sku || "—"}</Td><Td>{ITEM_TYPE_LABEL[p.item_type] || "للبيع"}</Td><Td>{p.archived_reason || "—"}</Td><Td>{p.archived_at ? new Date(p.archived_at).toLocaleDateString("ar-EG") : "—"}</Td><Td>{canArchive && <button aria-label={`استعادة ${p.name}`} onClick={() => restoreProduct(p)} style={{background:"none",border:"none",cursor:"pointer",color:C.green}}><RotateCcw size={15}/></button>}</Td></tr>)}</Table>}
      </ArchiveSection>
    </div>
  );
}

/* -------------------------------- Production -------------------------------- */
const ProductionTab=ProductionWorkspace;

/* ----------------------------------- Sales ---------------------------------- */
function SalesTab({ data, insertRow, refresh, canManage }) {
  const [form, setForm] = useState({ productId: "", customerId: "", qty: "", unitPrice: "", date: todayStr() });
  const [err, setErr] = useState(""); const [ok, setOk] = useState("");
  const [cancelAction, setCancelAction] = useState(null);
  const selectedProduct = data.products.find((p) => p.id === form.productId);

  async function submit() {
    setErr(""); setOk("");
    if (!form.productId) return setErr("اختر المنتج");
    if (!form.customerId) return setErr("اختر العميل");
    const qty = num(form.qty);
    if (qty <= 0) return setErr("أدخل كمية أكبر من صفر");
    const stock = finishedStock(form.productId, data);
    if (stock < qty) return setErr(`المخزون التام المتاح ${stock} وحدة فقط`);
    const unitPrice = num(form.unitPrice) || selectedProduct.selling_price;
    if (!Number.isFinite(unitPrice) || unitPrice <= 0) return setErr("سعر الوحدة يجب أن يكون أكبر من صفر");
    const total = unitPrice * qty;
    const e = await insertRow("sales", { product_id: form.productId, customer_id: form.customerId, qty, unit_price: unitPrice, total, sale_date: form.date });
    if (e) return setErr(e);
    setOk("تم تسجيل عملية البيع وتحديث مخزون المنتج التام وحساب العميل");
    setForm({ productId: "", customerId: "", qty: "", unitPrice: "", date: todayStr() });
  }

  async function confirmCancelSale() {
    const { row, reason } = cancelAction;
    setCancelAction((current)=>({...current,busy:true,error:""}));
    setErr(""); setOk("");
    const result = await runCriticalMutation({ scope:"sales:cancel", mutate:()=>supabase.rpc("cancel_sale",{target_sale_id:row.id,reason:reason.trim()}), verify:async()=>{
      const verification=await supabase.from("sales").select("status,cancelled_at").eq("id",row.id).single();
      return verification.error?verification:verification.data?.status==="cancelled";
    }, refetch:refresh });
    if (result.error) return setCancelAction((current)=>({...current,busy:false,error:result.mutationSaved?"وصل أمر الإلغاء للخادم، لكن تعذر التحقق. حدّث الشاشة قبل إعادة المحاولة.":result.error.message}));
    setCancelAction(null);
    setOk(result.refreshError ? "تم إلغاء البيع وحفظه، لكن تعذر تحديث الشاشة. حدّث الصفحة دون إعادة الإلغاء." : "تم إلغاء البيع، واستُبعد من الرصيد والإيراد مع حفظ أثر المراجعة.");
  }

  const postedSales = data.sales.filter((sale) => sale.status !== "cancelled");
  const cancelledSales = data.sales.filter((sale) => sale.status === "cancelled");
  const invalidLegacySale = (sale) => num(sale.qty) <= 0 || num(sale.unit_price) < 0 || num(sale.total) < 0 || num(sale.total) !== num(sale.qty) * num(sale.unit_price);

  return (
    <div>
      <SectionTitle eyebrow="التوزيع" title="المبيعات" icon={<ShoppingCart size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>عملية بيع جديدة</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="المنتج"><Select value={form.productId} onChange={(e) => setForm({ ...form, productId: e.target.value })}><option value="">اختر المنتج</option>{data.products.filter((p) => !p.archived_at && (p.item_type || "sale") !== "rental").map((p) => <option key={p.id} value={p.id}>{p.name} (متاح: {finishedStock(p.id, data)})</option>)}</Select></Field>
          <Field label="العميل"><Select value={form.customerId} onChange={(e) => setForm({ ...form, customerId: e.target.value })}><option value="">اختر العميل</option>{data.customers.filter((c) => !c.archived_at).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
          <Field label="الكمية"><Input type="number" value={form.qty} onChange={(e) => setForm({ ...form, qty: e.target.value })} /></Field>
          <Field label="سعر الوحدة"><Input type="number" value={form.unitPrice} onChange={(e) => setForm({ ...form, unitPrice: e.target.value })} placeholder={selectedProduct ? `افتراضي: ${fmt(selectedProduct.selling_price)}` : ""} /></Field>
          <Field label="التاريخ"><Input type="date" value={form.date} onChange={(e) => setForm({ ...form, date: e.target.value })} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn onClick={submit}><Plus size={15} /> تسجيل البيع</Btn></div>
        {err && <Banner type="error">{err}</Banner>}
        {ok && <Banner type="success">{ok}</Banner>}
      </Card>
      <Card>
        {postedSales.length === 0 ? <Empty text="لا توجد مبيعات مسجلة بعد" /> : (
          <Table headers={["التاريخ", "المنتج", "العميل", "الكمية", "سعر الوحدة", "الإجمالي", "الحالة", ""]}>
            {[...postedSales].reverse().map((s) => { const p = data.products.find((x) => x.id === s.product_id); const c = data.customers.find((x) => x.id === s.customer_id); return (
              <tr key={s.id}><Td>{s.sale_date}</Td><Td>{p?.name || "—"}</Td><Td>{c?.name || "—"}</Td><Td>{s.qty}</Td><Td>{formatMoney(s.unit_price)}</Td><Td style={{ fontWeight: 700, color: invalidLegacySale(s) ? C.red : C.green }}>{formatMoney(s.total)}</Td><Td>{invalidLegacySale(s) ? <span style={{color:C.red,fontWeight:700}}>سجل قديم يحتاج مراجعة</span> : "مرحّل"}</Td><Td>{canManage && <button aria-label="إلغاء البيع" title="إلغاء البيع وعكس أثره" onClick={() => setCancelAction({row:s,reason:"",busy:false,error:""})} style={{background:"none",border:"none",cursor:"pointer",color:C.red}}><X size={15}/></button>}</Td></tr>
            ); })}
          </Table>
        )}
      </Card>
      <ArchiveSection title="المبيعات الملغاة" count={cancelledSales.length} helpText="السجلات الملغاة محفوظة للمراجعة، ولا تدخل في المخزون أو الإيراد أو رصيد العميل.">
        {cancelledSales.length === 0 ? <Empty text="لا توجد مبيعات ملغاة" /> : <Table headers={["التاريخ", "المنتج", "العميل", "الإجمالي", "سبب الإلغاء", "وقت الإلغاء"]}>{[...cancelledSales].reverse().map((s) => <tr key={s.id}><Td>{s.sale_date}</Td><Td>{data.products.find((p) => p.id === s.product_id)?.name || "—"}</Td><Td>{data.customers.find((c) => c.id === s.customer_id)?.name || "—"}</Td><Td>{formatMoney(s.total)}</Td><Td>{s.cancellation_reason || "—"}</Td><Td>{s.cancelled_at ? new Date(s.cancelled_at).toLocaleString("ar-EG") : "—"}</Td></tr>)}</Table>}
      </ArchiveSection>
      <ConfirmDialog open={Boolean(cancelAction)} title="إلغاء عملية البيع" description="سيبقى السجل محفوظًا، وسيُعكس أثره على المخزون ورصيد العميل مرة واحدة فقط." confirmLabel="إلغاء وعكس" danger reasonRequired reason={cancelAction?.reason||""} busy={cancelAction?.busy} error={cancelAction?.error} onReasonChange={(reason)=>setCancelAction((current)=>({...current,reason,error:""}))} onConfirm={confirmCancelSale} onCancel={()=>setCancelAction(null)}/>
    </div>
  );
}

/* --------------------------------- Rentals ----------------------------------- */
function RentalsTab({ data, insertRow, refresh, canManage }) {
  const [form, setForm] = useState({ productId: "", customerId: "", qty: "", rentalFee: "", startDate: todayStr(), expectedReturn: "" });
  const [err, setErr] = useState(""); const [ok, setOk] = useState("");
  const [cancelAction, setCancelAction] = useState(null);

  async function submit() {
    setErr(""); setOk("");
    if (!form.productId) return setErr("اختر الصنف");
    if (!form.customerId) return setErr("اختر العميل");
    const qty = num(form.qty);
    if (qty <= 0) return setErr("أدخل كمية أكبر من صفر");
    const stock = finishedStock(form.productId, data);
    if (stock < qty) return setErr(`المتاح ${stock} وحدة فقط (بعد خصم اللي مؤجر حاليًا)`);
    if (num(form.rentalFee) < 0) return setErr("قيمة الإيجار لا يمكن أن تكون سالبة");
    if (form.expectedReturn && form.expectedReturn < form.startDate) return setErr("تاريخ الاسترجاع المتوقع لا يمكن أن يسبق تاريخ البداية");
    const e = await insertRow("rentals", {
      product_id: form.productId, customer_id: form.customerId, qty,
      rental_fee: num(form.rentalFee), start_date: form.startDate,
      expected_return_date: form.expectedReturn || null, status: "active",
    });
    if (e) return setErr(e);
    setOk("تم تسجيل الإيجار وخصم الكمية من المتاح");
    setForm({ productId: "", customerId: "", qty: "", rentalFee: "", startDate: todayStr(), expectedReturn: "" });
  }
  async function markReturned(r) {
    setErr(""); setOk("");
    const mutationResult = await supabase.rpc("mark_rental_returned", { target_rental_id: r.id, target_return_date: todayStr() });
    const result = await syncMutation({ scope: "rentals:return", mutationResult, refetch: refresh });
    if (result.error) return setErr(result.error.message);
    setOk("تم تسجيل إرجاع الصنف بنجاح");
  }

  const rentalProducts = data.products.filter((p) => !p.archived_at && (p.item_type || "sale") !== "sale");

  async function confirmCancelRental() {
    const { row, reason } = cancelAction;
    setCancelAction((current)=>({...current,busy:true,error:""}));
    setErr(""); setOk("");
    const result=await runCriticalMutation({scope:"rentals:cancel",mutate:()=>supabase.rpc("cancel_rental",{target_rental_id:row.id,reason:reason.trim()}),verify:async()=>{
      const verification=await supabase.from("rentals").select("status,cancelled_at").eq("id",row.id).single();
      return verification.error?verification:verification.data?.status==="cancelled";
    },refetch:refresh});
    if(result.error)return setCancelAction((current)=>({...current,busy:false,error:result.mutationSaved?"وصل أمر الإلغاء للخادم، لكن تعذر التحقق. حدّث الشاشة قبل إعادة المحاولة.":result.error.message}));
    setCancelAction(null);setOk(result.refreshError?"تم إلغاء الإيجار، لكن تعذر تحديث الشاشة. حدّث الصفحة دون إعادة الإلغاء.":"تم إلغاء الإيجار واستبعاده من الرصيد والمتاح مع حفظ أثر المراجعة.");
  }

  const activeRentals = data.rentals.filter((rental) => rental.status === "active");
  const rentalHistory = data.rentals.filter((rental) => rental.status !== "active");

  return (
    <div>
      <SectionTitle eyebrow="التأجير" title="الإيجارات" icon={<CalendarClock size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>عملية إيجار جديدة</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="الصنف"><Select value={form.productId} onChange={(e) => setForm({ ...form, productId: e.target.value })}><option value="">اختر الصنف</option>{rentalProducts.map((p) => <option key={p.id} value={p.id}>{p.name} (متاح: {finishedStock(p.id, data)})</option>)}</Select></Field>
          <Field label="العميل"><Select value={form.customerId} onChange={(e) => setForm({ ...form, customerId: e.target.value })}><option value="">اختر العميل</option>{data.customers.filter((c) => !c.archived_at).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
          <Field label="الكمية"><Input type="number" value={form.qty} onChange={(e) => setForm({ ...form, qty: e.target.value })} /></Field>
          <Field label="قيمة الإيجار الإجمالية"><Input type="number" value={form.rentalFee} onChange={(e) => setForm({ ...form, rentalFee: e.target.value })} /></Field>
          <Field label="تاريخ البداية"><Input type="date" value={form.startDate} onChange={(e) => setForm({ ...form, startDate: e.target.value })} /></Field>
          <Field label="تاريخ الاسترجاع المتوقع"><Input type="date" value={form.expectedReturn} onChange={(e) => setForm({ ...form, expectedReturn: e.target.value })} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn onClick={submit}><Plus size={15} /> تسجيل الإيجار</Btn></div>
        {err && <Banner type="error">{err}</Banner>}
        {ok && <Banner type="success">{ok}</Banner>}
      </Card>
      <Card>
        {activeRentals.length === 0 ? <Empty text="لا توجد عمليات إيجار نشطة" /> : (
          <Table headers={["الصنف", "العميل", "الكمية", "القيمة", "تاريخ البداية", "الاسترجاع المتوقع", "الحالة", ""]}>
            {[...activeRentals].reverse().map((r) => {
              const p = data.products.find((x) => x.id === r.product_id);
              const c = data.customers.find((x) => x.id === r.customer_id);
              return (
                <tr key={r.id}>
                  <Td>{p?.name || "—"}</Td><Td>{c?.name || "—"}</Td><Td>{r.qty}</Td>
                  <Td>{formatMoney(r.rental_fee)}</Td><Td>{r.start_date}</Td><Td>{r.expected_return_date || "—"}</Td>
                  <Td style={{ color: C.brass, fontWeight: 700 }}>مؤجر حاليًا</Td>
                  <Td><div style={{display:"flex",gap:8,alignItems:"center"}}><Btn variant="ghost" onClick={() => markReturned(r)} style={{ fontSize: 12, padding: "5px 10px" }}>تسجيل الاسترجاع</Btn>{canManage && <button aria-label="إلغاء الإيجار" title="إلغاء الإيجار وعكس أثره" onClick={() => setCancelAction({row:r,reason:"",busy:false,error:""})} style={{background:"none",border:"none",cursor:"pointer",color:C.red}}><X size={15}/></button>}</div></Td>
                </tr>
              );
            })}
          </Table>
        )}
      </Card>
      <ArchiveSection title="سجل الإيجارات المكتملة والملغاة" count={rentalHistory.length} helpText="الإرجاعات والإلغاءات نهائية ومحفوظة للمراجعة، ولا تزاحم الإيجارات النشطة.">
        {rentalHistory.length === 0 ? <Empty text="لا يوجد سجل إيجارات سابق" /> : <Table headers={["الصنف", "العميل", "الكمية", "القيمة", "الحالة", "التاريخ النهائي", "السبب"]}>{[...rentalHistory].reverse().map((r) => <tr key={r.id}><Td>{data.products.find((p) => p.id === r.product_id)?.name || "—"}</Td><Td>{data.customers.find((c) => c.id === r.customer_id)?.name || "—"}</Td><Td>{r.qty}</Td><Td>{formatMoney(r.rental_fee)}</Td><Td style={{color:r.status === "returned" ? C.green : C.red,fontWeight:700}}>{r.status === "returned" ? "تم الاسترجاع" : "ملغي"}</Td><Td>{r.status === "returned" ? r.return_date || "—" : r.cancelled_at ? new Date(r.cancelled_at).toLocaleString("ar-EG") : "—"}</Td><Td>{r.cancellation_reason || "—"}</Td></tr>)}</Table>}
      </ArchiveSection>
      <ConfirmDialog open={Boolean(cancelAction)} title="إلغاء عملية الإيجار" description="سيبقى السجل محفوظًا وستعود الكمية للمتاح. الطلب المكرر لن يطبق الإلغاء مرتين." confirmLabel="إلغاء وعكس" danger reasonRequired reason={cancelAction?.reason||""} busy={cancelAction?.busy} error={cancelAction?.error} onReasonChange={(reason)=>setCancelAction((current)=>({...current,reason,error:""}))} onConfirm={confirmCancelRental} onCancel={()=>setCancelAction(null)}/>
    </div>
  );
}

/* -------------------------------- Suppliers --------------------------------- */
function SuppliersTab({ data, insertRow, updateRow, refresh, canManage }) {
  const [name, setName] = useState(""); const [phone, setPhone] = useState("");
  const [editingId, setEditingId] = useState(null);
  const [payment, setPayment] = useState({ supplierId: "", amount: "", date: todayStr(), commandId: "" });
  const [err, setErr] = useState(""); const [expanded, setExpanded] = useState(null);
  const [search, setSearch] = useState("");
  const [pendingPayment, setPendingPayment] = useState(null); const [paymentBusy, setPaymentBusy] = useState(false);

  function startEdit(s) { setEditingId(s.id); setName(s.name); setPhone(s.phone || ""); }
  function cancelEdit() { setEditingId(null); setName(""); setPhone(""); setErr(""); }
  async function submitSupplier() {
    if (!name.trim()) return setErr("اكتب اسم المورد");
    const payload = { name: name.trim(), phone: phone.trim() };
    const e = editingId ? await updateRow("suppliers", editingId, payload) : await insertRow("suppliers", payload);
    if (e) return setErr(e);
    setName(""); setPhone(""); setEditingId(null); setErr("");
  }
  async function commitPayment(payload = payment) {
    setPaymentBusy(true); setErr("");
    const commandId = payload.commandId || globalThis.crypto.randomUUID();
    if (!payload.commandId) { setPayment((current) => ({ ...current, commandId })); setPendingPayment((current) => current ? ({ ...current, commandId }) : current); }
    const result = await supabase.rpc("record_supplier_payment", { target_supplier: payload.supplierId, payment_amount: num(payload.amount), paid_on: payload.date, payment_note: null, command_id: commandId });
    if (result.error) { setPaymentBusy(false); return setErr(result.error.message); }
    const refreshed = await refresh();
    setPaymentBusy(false); setPendingPayment(null);
    if (refreshed?.error) return setErr("تم حفظ الدفعة، لكن تعذر تحديث الشاشة. حدّث الصفحة بأمان؛ لا تعِد تسجيل الدفعة.");
    setPayment({ supplierId: "", amount: "", date: todayStr(), commandId: "" });
  }
  async function addPayment() {
    if (!payment.supplierId) return setErr("اختر المورد");
    if (num(payment.amount) <= 0) return setErr("أدخل مبلغ أكبر من صفر");
    const due = supplierBalances(payment.supplierId, data).due;
    if (num(payment.amount) > due) return setPendingPayment({ ...payment, due, advance: num(payment.amount) - due });
    await commitPayment();
  }
  async function archiveSupplier(supplier) {
    const reason = window.prompt(`سبب أرشفة المورد "${supplier.name}"؟`);
    if (!reason?.trim()) return;
    if (!window.confirm("سيُمنع المورد من المعاملات الجديدة مع الاحتفاظ بكل تاريخه. متابعة؟")) return;
    const e = await updateRow("suppliers", supplier.id, { archived_at: new Date().toISOString(), archived_reason: reason.trim() });
    if (e) return setErr(e);
    if (editingId === supplier.id) cancelEdit();
    setErr("");
  }
  async function restoreSupplier(supplier) {
    if (!window.confirm(`استعادة المورد "${supplier.name}" للمعاملات الجديدة؟`)) return;
    const e = await updateRow("suppliers", supplier.id, { archived_at: null, archived_reason: null });
    if (e) setErr(e); else setErr("");
  }
  const activeSuppliers = data.suppliers.filter((supplier) => !supplier.archived_at);
  const archivedSuppliers = data.suppliers.filter((supplier) => supplier.archived_at);
  const matchesSearch = (supplier) => supplier.name.toLowerCase().includes(search.toLowerCase());
  const filtered = activeSuppliers.filter(matchesSearch);
  const filteredArchived = archivedSuppliers.filter(matchesSearch);

  return (
    <div>
      <SectionTitle eyebrow="دفتر أستاذ مساعد" title="الموردين" icon={<Truck size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>{editingId ? "تعديل مورد" : "مورد جديد"}</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="اسم المورد"><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label="رقم الهاتف"><Input value={phone} onChange={(e) => setPhone(e.target.value)} /></Field>
        </div>
        <div style={{ marginTop: 12, display: "flex", gap: 8 }}>
          <Btn onClick={submitSupplier}>{editingId ? <><Pencil size={15} /> حفظ التعديل</> : <><Plus size={15} /> إضافة</>}</Btn>
          {editingId && <Btn variant="ghost" onClick={cancelEdit}><X size={15} /> إلغاء</Btn>}
        </div>
      </Card>
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>تسجيل دفعة لمورد</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="المورد"><Select value={payment.supplierId} onChange={(e) => setPayment({ ...payment, supplierId: e.target.value, commandId:"" })}><option value="">اختر المورد</option>{activeSuppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
          <Field label="المبلغ"><Input type="number" value={payment.amount} onChange={(e) => setPayment({ ...payment, amount: e.target.value, commandId:"" })} /></Field>
          <Field label="التاريخ"><Input type="date" value={payment.date} onChange={(e) => setPayment({ ...payment, date: e.target.value, commandId:"" })} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn disabled={paymentBusy} onClick={addPayment}><Wallet size={15} /> {paymentBusy ? "جارِ التسجيل..." : "تسجيل الدفعة"}</Btn></div>
        {err && <Banner>{err}</Banner>}
      </Card>
      <Card>
        <SearchBox value={search} onChange={setSearch} placeholder="ابحث باسم المورد..." />
        {filtered.length === 0 ? <Empty text="لا توجد نتائج" /> : (
          <Table headers={["المورد", "الهاتف", "إجمالي المشتريات", "إجمالي المدفوع", "المستحق", "السلفة", ""]}>
            {filtered.map((s) => { const balances = supplierBalances(s.id, data); const bal = balances.due; return (
              <React.Fragment key={s.id}>
                <tr>
                  <Td>{s.name}</Td><Td>{s.phone || "—"}</Td><Td>{formatMoney(supplierPurchaseTotal(s.id, data))}</Td><Td>{formatMoney(supplierPaymentTotal(s.id, data))}</Td>
                  <Td style={{ fontWeight: 700, color: bal > 0 ? C.red : C.green }}>{formatMoney(bal)}</Td><Td style={{fontWeight:700,color:C.green}}>{formatMoney(balances.advance)}{balances.legacyUnclassified>0&&<small style={{display:"block",color:C.red}}>يوجد {balances.legacyUnclassified} حركة قديمة غير مصنفة</small>}</Td>
                  <Td style={{ display: "flex", gap: 10, alignItems: "center" }}>
                    <button aria-label={`تعديل ${s.name}`} title="تعديل المورد" onClick={() => startEdit(s)} style={{ background: "none", border: "none", cursor: "pointer", color: C.brass }}><Pencil size={15} /></button>
                    {canManage && <button aria-label={`أرشفة ${s.name}`} onClick={() => archiveSupplier(s)} style={{ background: "none", border: "none", cursor: "pointer", color: C.red }}><Archive size={15} /></button>}
                    <button onClick={() => setExpanded(expanded === s.id ? null : s.id)} style={{ background: "none", border: "none", color: C.brass, cursor: "pointer", fontSize: 12.5 }}>{expanded === s.id ? "إخفاء الحركات" : "عرض الحركات"}</button>
                  </Td>
                </tr>
                {expanded === s.id && <tr><Td colSpan={7} style={{ background: C.panelAlt }}><SupplierLedger supplierId={s.id} data={data} /><CommercialAdvancesPanel partyType="supplier" partyId={s.id} canReverse={canManage} onChanged={refresh}/></Td></tr>}
              </React.Fragment>
            ); })}
          </Table>
        )}
      </Card>
      <ArchiveSection title="الموردون المؤرشفون" count={archivedSuppliers.length} helpText="محفوظون للتاريخ ولا يظهرون في المعاملات الجديدة. يمكن للمدير استعادة المورد عند الحاجة.">
        {filteredArchived.length === 0 ? <Empty text="لا توجد سجلات مؤرشفة مطابقة" /> : (
          <Table headers={["المورد", "الهاتف", "سبب الأرشفة", "تاريخ الأرشفة", ""]}>
            {filteredArchived.map((s) => <tr key={s.id}><Td>{s.name}</Td><Td>{s.phone || "—"}</Td><Td>{s.archived_reason || "—"}</Td><Td>{s.archived_at ? new Date(s.archived_at).toLocaleDateString("ar-EG") : "—"}</Td><Td>{canManage && <button aria-label={`استعادة ${s.name}`} onClick={() => restoreSupplier(s)} style={{ background: "none", border: "none", cursor: "pointer", color: C.green }}><RotateCcw size={15} /></button>}</Td></tr>)}
          </Table>
        )}
      </ArchiveSection>
      <ConfirmDialog open={Boolean(pendingPayment)} title="تسجيل سلفة مورد" description={pendingPayment ? `المستحق ${formatMoney(pendingPayment.due)}، وسيُصنف المبلغ الزائد ${formatMoney(pendingPayment.advance)} كسلفة مورد متاحة للتخصيص لاحقًا.` : ""} confirmLabel="تسجيل الدفعة والسلفة" danger={false} busy={paymentBusy} onConfirm={() => pendingPayment && commitPayment(pendingPayment)} onCancel={() => !paymentBusy && setPendingPayment(null)} />
    </div>
  );
}
function SupplierLedger({ supplierId, data }) {
  const purchases = data.materialPurchases.filter((p) => p.supplier_id === supplierId).map((p) => ({ date: p.purchase_date, type: "شراء", amount: p.qty * p.unit_cost, note: data.materials.find((m) => m.id === p.material_id)?.name }));
  const payments = data.supplierPayments.filter((p) => p.supplier_id === supplierId).map((p) => ({ date: p.payment_date, type: transactionClassLabel(p), amount: -p.amount, note: p.note }));
  const rows = [...purchases, ...payments].sort((a, b) => (a.date || "").localeCompare(b.date || ""));
  if (rows.length === 0) return <div style={{ color: C.muted, fontSize: 13 }}>لا توجد حركات مسجلة</div>;
  return <Table headers={["التاريخ", "النوع", "البيان", "المبلغ"]}>{rows.map((r, i) => <tr key={i}><Td>{r.date}</Td><Td style={{ color: r.type === "شراء" ? C.red : C.green }}>{r.type}</Td><Td>{r.note || "—"}</Td><Td>{formatMoney(Math.abs(r.amount))}</Td></tr>)}</Table>;
}

/* -------------------------------- Customers --------------------------------- */
function CustomersTab({ data, insertRow, updateRow, refresh, canManage }) {
  const [name, setName] = useState(""); const [phone, setPhone] = useState("");
  const [editingId, setEditingId] = useState(null);
  const [receipt, setReceipt] = useState({ customerId: "", amount: "", date: todayStr(), commandId: "" });
  const [err, setErr] = useState(""); const [expanded, setExpanded] = useState(null);
  const [search, setSearch] = useState("");
  const [pendingReceipt, setPendingReceipt] = useState(null); const [receiptBusy, setReceiptBusy] = useState(false);

  function startEdit(c) { setEditingId(c.id); setName(c.name); setPhone(c.phone || ""); }
  function cancelEdit() { setEditingId(null); setName(""); setPhone(""); setErr(""); }
  async function submitCustomer() {
    if (!name.trim()) return setErr("اكتب اسم العميل");
    const payload = { name: name.trim(), phone: phone.trim() };
    const e = editingId ? await updateRow("customers", editingId, payload) : await insertRow("customers", payload);
    if (e) return setErr(e);
    setName(""); setPhone(""); setEditingId(null); setErr("");
  }
  async function commitReceipt(payload = receipt) {
    setReceiptBusy(true); setErr("");
    const commandId = payload.commandId || globalThis.crypto.randomUUID();
    if (!payload.commandId) { setReceipt((current) => ({ ...current, commandId })); setPendingReceipt((current) => current ? ({ ...current, commandId }) : current); }
    const result = await supabase.rpc("record_customer_receipt", { target_customer: payload.customerId, receipt_amount: num(payload.amount), received_on: payload.date, receipt_note: null, command_id: commandId });
    if (result.error) { setReceiptBusy(false); return setErr(result.error.message); }
    const refreshed = await refresh();
    setReceiptBusy(false); setPendingReceipt(null);
    if (refreshed?.error) return setErr("تم حفظ التحصيل، لكن تعذر تحديث الشاشة. حدّث الصفحة بأمان؛ لا تعِد تسجيل التحصيل.");
    setReceipt({ customerId: "", amount: "", date: todayStr(), commandId: "" });
  }
  async function addReceipt() {
    if (!receipt.customerId) return setErr("اختر العميل");
    if (num(receipt.amount) <= 0) return setErr("أدخل مبلغ أكبر من صفر");
    const due = customerBalances(receipt.customerId, data).due;
    if (num(receipt.amount) > due) return setPendingReceipt({ ...receipt, due, advance: num(receipt.amount) - due });
    await commitReceipt();
  }
  async function archiveCustomer(customer) {
    const reason = window.prompt(`سبب أرشفة العميل "${customer.name}"؟`);
    if (!reason?.trim()) return;
    if (!window.confirm("سيُمنع العميل من المعاملات الجديدة مع الاحتفاظ بكل تاريخه. متابعة؟")) return;
    const e = await updateRow("customers", customer.id, { archived_at: new Date().toISOString(), archived_reason: reason.trim() });
    if (e) return setErr(e);
    if (editingId === customer.id) cancelEdit();
    setErr("");
  }
  async function restoreCustomer(customer) {
    if (!window.confirm(`استعادة العميل "${customer.name}" للمعاملات الجديدة؟`)) return;
    const e = await updateRow("customers", customer.id, { archived_at: null, archived_reason: null });
    if (e) setErr(e); else setErr("");
  }
  const activeCustomers = data.customers.filter((customer) => !customer.archived_at);
  const archivedCustomers = data.customers.filter((customer) => customer.archived_at);
  const matchesSearch = (customer) => customer.name.toLowerCase().includes(search.toLowerCase());
  const filtered = activeCustomers.filter(matchesSearch);
  const filteredArchived = archivedCustomers.filter(matchesSearch);

  return (
    <div>
      <SectionTitle eyebrow="دفتر أستاذ مساعد" title="العملاء" icon={<Users size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>{editingId ? "تعديل عميل" : "عميل جديد"}</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="اسم العميل"><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label="رقم الهاتف"><Input value={phone} onChange={(e) => setPhone(e.target.value)} /></Field>
        </div>
        <div style={{ marginTop: 12, display: "flex", gap: 8 }}>
          <Btn onClick={submitCustomer}>{editingId ? <><Pencil size={15} /> حفظ التعديل</> : <><Plus size={15} /> إضافة</>}</Btn>
          {editingId && <Btn variant="ghost" onClick={cancelEdit}><X size={15} /> إلغاء</Btn>}
        </div>
      </Card>
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>تسجيل تحصيل من عميل</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="العميل"><Select value={receipt.customerId} onChange={(e) => setReceipt({ ...receipt, customerId: e.target.value, commandId:"" })}><option value="">اختر العميل</option>{activeCustomers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
          <Field label="المبلغ"><Input type="number" value={receipt.amount} onChange={(e) => setReceipt({ ...receipt, amount: e.target.value, commandId:"" })} /></Field>
          <Field label="التاريخ"><Input type="date" value={receipt.date} onChange={(e) => setReceipt({ ...receipt, date: e.target.value, commandId:"" })} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn disabled={receiptBusy} onClick={addReceipt}><Wallet size={15} /> {receiptBusy ? "جارِ التسجيل..." : "تسجيل التحصيل"}</Btn></div>
        {err && <Banner>{err}</Banner>}
      </Card>
      <Card>
        <SearchBox value={search} onChange={setSearch} placeholder="ابحث باسم العميل..." />
        {filtered.length === 0 ? <Empty text="لا توجد نتائج" /> : (
          <Table headers={["العميل", "الهاتف", "إجمالي المبيعات والإيجارات", "إجمالي التحصيل", "المستحق", "السلفة", ""]}>
            {filtered.map((c) => { const balances = customerBalances(c.id, data); const bal = balances.due; return (
              <React.Fragment key={c.id}>
                <tr>
                  <Td>{c.name}</Td><Td>{c.phone || "—"}</Td><Td>{formatMoney(customerSaleTotal(c.id, data) + customerRentalTotal(c.id, data))}</Td><Td>{formatMoney(customerReceiptTotal(c.id, data))}</Td>
                  <Td style={{ fontWeight: 700, color: bal > 0 ? C.brass : C.green }}>{formatMoney(bal)}</Td><Td style={{fontWeight:700,color:C.green}}>{formatMoney(balances.advance)}{balances.legacyUnclassified>0&&<small style={{display:"block",color:C.red}}>يوجد {balances.legacyUnclassified} حركة قديمة غير مصنفة</small>}</Td>
                  <Td style={{ display: "flex", gap: 10, alignItems: "center" }}>
                    <button aria-label={`تعديل ${c.name}`} title="تعديل العميل" onClick={() => startEdit(c)} style={{ background: "none", border: "none", cursor: "pointer", color: C.brass }}><Pencil size={15} /></button>
                    {canManage && <button aria-label={`أرشفة ${c.name}`} onClick={() => archiveCustomer(c)} style={{ background: "none", border: "none", cursor: "pointer", color: C.red }}><Archive size={15} /></button>}
                    <button onClick={() => setExpanded(expanded === c.id ? null : c.id)} style={{ background: "none", border: "none", color: C.brass, cursor: "pointer", fontSize: 12.5 }}>{expanded === c.id ? "إخفاء الحركات" : "عرض الحركات"}</button>
                  </Td>
                </tr>
                {expanded === c.id && <tr><Td colSpan={7} style={{ background: C.panelAlt }}><CustomerLedger customerId={c.id} data={data} /><CommercialAdvancesPanel partyType="customer" partyId={c.id} canReverse={canManage} onChanged={refresh}/></Td></tr>}
              </React.Fragment>
            ); })}
          </Table>
        )}
      </Card>
      <ArchiveSection title="العملاء المؤرشفون" count={archivedCustomers.length} helpText="محفوظون للتاريخ ولا يظهرون في المعاملات الجديدة. يمكن للمدير استعادة العميل عند الحاجة.">
        {filteredArchived.length === 0 ? <Empty text="لا توجد سجلات مؤرشفة مطابقة" /> : (
          <Table headers={["العميل", "الهاتف", "سبب الأرشفة", "تاريخ الأرشفة", ""]}>
            {filteredArchived.map((c) => <tr key={c.id}><Td>{c.name}</Td><Td>{c.phone || "—"}</Td><Td>{c.archived_reason || "—"}</Td><Td>{c.archived_at ? new Date(c.archived_at).toLocaleDateString("ar-EG") : "—"}</Td><Td>{canManage && <button aria-label={`استعادة ${c.name}`} onClick={() => restoreCustomer(c)} style={{ background: "none", border: "none", cursor: "pointer", color: C.green }}><RotateCcw size={15} /></button>}</Td></tr>)}
          </Table>
        )}
      </ArchiveSection>
      <ConfirmDialog open={Boolean(pendingReceipt)} title="تسجيل سلفة عميل" description={pendingReceipt ? `المستحق ${formatMoney(pendingReceipt.due)}، وسيُصنف المبلغ الزائد ${formatMoney(pendingReceipt.advance)} كسلفة عميل متاحة للتخصيص لاحقًا.` : ""} confirmLabel="تسجيل التحصيل والسلفة" busy={receiptBusy} onConfirm={() => pendingReceipt && commitReceipt(pendingReceipt)} onCancel={() => !receiptBusy && setPendingReceipt(null)} />
    </div>
  );
}
function CustomerLedger({ customerId, data }) {
  const sales = data.sales.filter((s) => s.customer_id === customerId).map((s) => ({ date: s.sale_date, type: s.status === "cancelled" ? "بيع ملغي" : "بيع", amount: s.status === "cancelled" ? 0 : s.total, note: `${data.products.find((p) => p.id === s.product_id)?.name || "—"}${s.status === "cancelled" ? ` — ${s.cancellation_reason || "ملغي"}` : ""}` }));
  const rentals = data.rentals.filter((r) => r.customer_id === customerId).map((r) => ({ date: r.start_date, type: r.status === "cancelled" ? "إيجار ملغي" : "إيجار", amount: r.status === "cancelled" ? 0 : r.rental_fee, note: `${data.products.find((p) => p.id === r.product_id)?.name || "—"}${r.status === "cancelled" ? ` — ${r.cancellation_reason || "ملغي"}` : ""}` }));
  const receipts = data.customerReceipts.filter((r) => r.customer_id === customerId).map((r) => ({ date: r.receipt_date, type: transactionClassLabel(r), amount: -r.amount, note: r.note }));
  const rows = [...sales, ...rentals, ...receipts].sort((a, b) => (a.date || "").localeCompare(b.date || ""));
  if (rows.length === 0) return <div style={{ color: C.muted, fontSize: 13 }}>لا توجد حركات مسجلة</div>;
  return <Table headers={["التاريخ", "النوع", "البيان", "المبلغ"]}>{rows.map((r, i) => <tr key={i}><Td>{r.date}</Td><Td style={{ color: r.type === "تحصيل" ? C.green : C.brass }}>{r.type}</Td><Td>{r.note || "—"}</Td><Td>{formatMoney(Math.abs(r.amount))}</Td></tr>)}</Table>;
}


/* -------------------------------- Purchases -------------------------------- */
function PurchasesTab({ data, insertRow, deleteRow, canDelete }) {
  const [form, setForm] = useState({ materialId: "", supplierId: "", qty: "", unitCost: "", date: todayStr() });
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");

  async function submit() {
    setErr(""); setOk("");
    if (!form.materialId) return setErr("اختر المادة الخام");
    if (num(form.qty) <= 0) return setErr("أدخل كمية أكبر من صفر");
    if (num(form.unitCost) < 0) return setErr("سعر الوحدة غير صحيح");
    const e = await insertRow("materialPurchases", {
      material_id: form.materialId,
      supplier_id: form.supplierId || null,
      qty: num(form.qty),
      unit_cost: num(form.unitCost),
      purchase_date: form.date,
    });
    if (e) return setErr(e);
    setOk("تم تسجيل المشتريات وزيادة المخزون بنجاح");
    setForm({ materialId: "", supplierId: "", qty: "", unitCost: "", date: todayStr() });
  }

  async function remove(row) {
    if (!window.confirm("متأكد من حذف عملية الشراء؟ سيتم تخفيض المخزون.")) return;
    const e = await deleteRow("materialPurchases", row.id);
    if (e) setErr(e);
  }

  const total = data.materialPurchases.reduce((sum, p) => sum + num(p.qty) * num(p.unit_cost), 0);
  return <div>
    <SectionTitle eyebrow="التوريد" title="المشتريات" icon={<ClipboardList size={14} />} />
    <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 14, marginBottom: 18 }}>
      <Card><div style={{ color: C.muted, fontSize: 13 }}>إجمالي قيمة المشتريات</div><div style={{ color: C.brass, fontSize: 23, fontWeight: 800, marginTop: 8 }}>{formatMoney(total)}</div></Card>
      <Card><div style={{ color: C.muted, fontSize: 13 }}>عدد عمليات الشراء</div><div style={{ color: C.green, fontSize: 23, fontWeight: 800, marginTop: 8 }}>{data.materialPurchases.length}</div></Card>
    </div>
    <Card style={{ marginBottom: 18 }}>
      <div style={{ fontWeight: 800, marginBottom: 12 }}>عملية شراء جديدة</div>
      <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
        <Field label="المادة"><Select value={form.materialId} onChange={(e) => setForm({ ...form, materialId: e.target.value })}><option value="">اختر المادة</option>{data.materials.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</Select></Field>
        <Field label="المورد"><Select value={form.supplierId} onChange={(e) => setForm({ ...form, supplierId: e.target.value })}><option value="">بدون مورد محدد</option>{data.suppliers.filter((s) => !s.archived_at).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
        <Field label="الكمية"><Input type="number" min="0" step="any" value={form.qty} onChange={(e) => setForm({ ...form, qty: e.target.value })} /></Field>
        <Field label="سعر الوحدة"><Input type="number" min="0" step="any" value={form.unitCost} onChange={(e) => setForm({ ...form, unitCost: e.target.value })} /></Field>
        <Field label="التاريخ"><Input type="date" value={form.date} onChange={(e) => setForm({ ...form, date: e.target.value })} /></Field>
      </div>
      <div style={{ marginTop: 12 }}><Btn onClick={submit}><Plus size={15}/> تسجيل الشراء</Btn></div>
      {err && <Banner type="error">{err}</Banner>}{ok && <Banner type="success">{ok}</Banner>}
    </Card>
    <Card>{data.materialPurchases.length === 0 ? <Empty text="لا توجد مشتريات مسجلة" /> : <Table headers={["التاريخ","المادة","المورد","الكمية","سعر الوحدة","الإجمالي",""]}>{[...data.materialPurchases].reverse().map((p) => {
      const m = data.materials.find((x) => x.id === p.material_id); const sup = data.suppliers.find((x) => x.id === p.supplier_id);
      return <tr key={p.id}><Td>{p.purchase_date}</Td><Td>{m?.name || "—"}</Td><Td>{sup?.name || "—"}</Td><Td>{p.qty} {m?.unit || ""}</Td><Td>{formatMoney(p.unit_cost)}</Td><Td style={{fontWeight:700}}>{formatMoney(num(p.qty)*num(p.unit_cost))}</Td><Td>{canDelete && <button onClick={() => remove(p)} style={{background:"none",border:"none",cursor:"pointer",color:C.red}}><Trash2 size={15}/></button>}</Td></tr>
    })}</Table>}</Card>
  </div>;
}

/* -------------------------------- Expenses --------------------------------- */
function ExpensesTab({ data, insertRow, profileRole, refresh }) {
  const categories = ["كهرباء", "إيجار", "رواتب", "نقل", "صيانة", "إنترنت", "تسويق", "أخرى"];
  const [form, setForm] = useState({ category: categories[0], amount: "", date: todayStr(), notes: "", projectId: "" });
  const [err, setErr] = useState(""); const [ok, setOk] = useState("");
  const [busyId, setBusyId] = useState(null);
  const [cancellingExpense, setCancellingExpense] = useState(null);
  const [cancelReason, setCancelReason] = useState("");
  async function submit() {
    setErr(""); setOk("");
    if (num(form.amount) <= 0) return setErr("أدخل مبلغ أكبر من صفر");
    const { data: authData } = await supabase.auth.getUser();
    const e = await insertRow("expenses", { category: form.category, amount: num(form.amount), expense_date: form.date, notes: form.notes.trim() || null, project_id: form.projectId || null, created_by: authData?.user?.id || null });
    if (e) return setErr(e);
    setOk("تم تسجيل المصروف بنجاح");
    setForm({ category: categories[0], amount: "", date: todayStr(), notes: "", projectId: "" });
  }
  async function runFinancialAction(name, row, reason = null) {
    setErr(""); setOk(""); setBusyId(row.id);
    const args = name === "prepare_operational_source_actual_cost"
      ? { target_source_type: "approved_expense", target_source_id: row.id }
      : { target_expense_id: row.id, reason };
    const { error } = await supabase.rpc(name, args);
    setBusyId(null);
    if (error) return setErr(error.message);
    await refresh();
    setOk(name === "cancel_expense" ? "تم إلغاء المصروف مع الحفاظ على سجله" : "تم إرسال المصروف لمراجعة التكلفة الفعلية");
  }
  async function cancel(row) {
    setCancelReason(""); setCancellingExpense(row);
  }
  async function confirmExpenseCancellation() {
    if (!cancelReason.trim()) return setErr("سبب الإلغاء مطلوب");
    await runFinancialAction("cancel_expense", cancellingExpense, cancelReason.trim());
    setCancellingExpense(null); setCancelReason("");
  }
  const activeExpenses = data.expenses.filter((expense) => !expense.cancelled_at);
  const total = activeExpenses.reduce((sum, e) => sum + num(e.amount), 0);
  return <div>
    <ConfirmDialog open={Boolean(cancellingExpense)} title="إلغاء المصروف" description="سيبقى المصروف ظاهرًا في السجل وتُحفظ حركة الإلغاء وسببها للتدقيق." confirmLabel="إلغاء المصروف" danger busy={busyId===cancellingExpense?.id} reasonRequired reason={cancelReason} onReasonChange={setCancelReason} error={cancellingExpense&&err?err:""} onConfirm={confirmExpenseCancellation} onCancel={()=>{setCancellingExpense(null);setCancelReason("")}}/>
    <SectionTitle eyebrow="المالية" title="المصروفات" icon={<ReceiptText size={14} />} />
    <Card style={{ marginBottom: 18 }}><div style={{ color: C.muted, fontSize: 13 }}>إجمالي المصروفات المسجلة</div><div style={{ color: C.red, fontSize: 24, fontWeight: 800, marginTop: 8 }}>{formatMoney(total)}</div></Card>
    <Card style={{ marginBottom: 18 }}>
      <div style={{ fontWeight: 800, marginBottom: 12 }}>مصروف جديد</div>
      <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
        <Field label="البند"><Select value={form.category} onChange={(e) => setForm({ ...form, category: e.target.value })}>{categories.map((c) => <option key={c} value={c}>{c}</option>)}</Select></Field>
        <Field label="المشروع (اختياري للمصروف العام)"><Select value={form.projectId} onChange={(e) => setForm({ ...form, projectId: e.target.value })}><option value="">مصروف عام بدون مشروع</option>{data.projects.filter((p) => !["closed"].includes(p.lifecycle)).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</Select></Field>
        <Field label="المبلغ"><Input type="number" min="0" step="any" value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} /></Field>
        <Field label="التاريخ"><Input type="date" value={form.date} onChange={(e) => setForm({ ...form, date: e.target.value })} /></Field>
        <Field label="ملاحظات"><Input value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} /></Field>
      </div>
      <div style={{ marginTop: 12 }}><Btn onClick={submit}><Plus size={15}/> تسجيل المصروف</Btn></div>
      {err && <Banner type="error">{err}</Banner>}{ok && <Banner type="success">{ok}</Banner>}
    </Card>
    <Card>{data.expenses.length === 0 ? <Empty text="لا توجد مصروفات مسجلة" /> : <Table headers={["التاريخ","البند","المشروع","الحالة","الملاحظات","المبلغ","الإجراءات"]}>{[...data.expenses].reverse().map((e) => {
      const project = data.projects.find((p) => p.id === e.project_id);
      const status = e.cancelled_at ? "ملغي" : ({not_posted:"غير مرحّل",submitted:"قيد المراجعة",posted:"مرحّل",rejected:"مرفوض",reversed:"معكوس"}[e.cost_posting_status] || e.cost_posting_status);
      const canCancel = ["owner","manager"].includes(profileRole) && !e.cancelled_at;
      return <tr key={e.id} style={{opacity:e.cancelled_at?0.65:1}}><Td>{e.expense_date}</Td><Td>{e.category}</Td><Td>{project?.name || "عام"}</Td><Td>{status}</Td><Td>{e.cancellation_reason || e.notes || "—"}</Td><Td style={{fontWeight:700,color:C.red}}>{formatMoney(e.amount)}</Td><Td><div style={{display:"flex",gap:6,flexWrap:"wrap"}}>{e.project_id && e.cost_posting_status === "not_posted" && !e.cancelled_at && <Btn disabled={busyId===e.id} onClick={() => runFinancialAction("prepare_operational_source_actual_cost", e)}>إرسال للتكلفة</Btn>}{canCancel && <Btn variant="danger" disabled={busyId===e.id} onClick={() => cancel(e)}>إلغاء</Btn>}</div></Td></tr>;
    })}</Table>}</Card>
  </div>;
}

/* ---------------------------------- Reports --------------------------------- */
function ReportsTab() {
  return <ReportingWorkspace />;
}

/* ----------------------------------- Team ------------------------------------ */
const GENERAL_PERMISSION_LABELS = {
  can_delete: "السماح بالحذف",
  view_financials: "عرض الأرباح والتقارير المالية",
  can_create_products: "إضافة منتجات جديدة",
  can_edit_products: "تعديل المنتجات الموجودة",
};
const PERMISSION_SECTIONS = [
  { id: "pages", label: "الصفحات والوحدات", type: "page", keys: ALL_PAGE_IDS.filter((page) => page !== "settings") },
  { id: "general", label: "الصلاحيات العامة", type: "permission", keys: Object.keys(GENERAL_PERMISSION_LABELS) },
  { id: "projects", label: "المشاريع والملفات", type: "permission", keys: ACTION_PERMISSIONS.filter((key) => key.startsWith("project")) },
  { id: "payroll", label: "الرواتب", type: "permission", keys: ACTION_PERMISSIONS.filter((key) => key.startsWith("payroll")) },
  { id: "labor", label: "العمالة اليومية", type: "permission", keys: ACTION_PERMISSIONS.filter((key) => key.startsWith("daily_labor")) },
  { id: "assets", label: "الأصول والعِدّة", type: "permission", keys: ACTION_PERMISSIONS.filter((key) => key.startsWith("assets_")) },
  { id: "audit", label: "التدقيق", type: "permission", keys: ["audit_log_view"] },
];

function TeamTab({ profiles, employees, refresh, currentProfile }) {
  const [pending, setPending] = useState({});
  const [newAccount, setNewAccount] = useState({ fullName: "", phone: "", temporaryPassword: "", role: MANAGER_ASSIGNABLE_ROLES[0] });
  const [message, setMessage] = useState({ type: "", text: "" });
  const [openSections, setOpenSections] = useState({});
  const [creatingAccount, setCreatingAccount] = useState(false);
  const [savingUserId, setSavingUserId] = useState(null);
  const [linkingUserId, setLinkingUserId] = useState(null);
  const [updatingPhoneUserId, setUpdatingPhoneUserId] = useState(null);
  const [linkReasons, setLinkReasons] = useState({});
  const [phoneReasons, setPhoneReasons] = useState({});

  useEffect(() => {
    const initial = {};
    for (const profile of profiles || []) initial[profile.id] = { role: profile.role, status: profile.status || "active", employee_id: profile.employee_id || "", phone: profile.phone || "", ...permissionsForProfile(profile) };
    setPending(initial);
    console.info("[permissions] currentState", initial);
  }, [profiles]);

  const load = useCallback(async () => {
    const fetchResult = await refresh("profiles");
    console.info("[permissions] refetchResult", fetchResult);
    return fetchResult;
  }, [refresh]);

  function patchUser(userId, patch) {
    setPending((previous) => ({ ...previous, [userId]: { ...(previous[userId] || {}), ...patch } }));
  }

  function itemAllowed(role, section, key) {
    if (role === "production") return (section.type === "page" && PRODUCTION_ALLOWED_PAGES.includes(key)) || (section.type === "permission" && [
      "assets_view", "assets_issue", "assets_return", "projects_view", "project_files_view",
      "project_files_upload", "projects_manage_milestones", "projects_update_progress",
    ].includes(key));
    if (role === "accountant") return !(section.type === "page" && ["team", "auditLog"].includes(key)) && key !== "audit_log_view";
    return true;
  }

  function isChecked(current, section, key) {
    return section.type === "page" ? (current.pages || []).includes(key) : Boolean(current[key]);
  }

  function setPermission(userId, section, key, checked) {
    const current = pending[userId] || {};
    if (section.type === "page") {
      const pages = new Set(current.pages || []);
      if (checked) pages.add(key); else pages.delete(key);
      patchUser(userId, { pages: [...pages] });
    } else patchUser(userId, { [key]: checked });
  }

  function setSection(userId, section, checked) {
    const current = pending[userId] || {};
    const allowedKeys = section.keys.filter((key) => itemAllowed(current.role, section, key));
    if (section.type === "page") {
      const pages = new Set(current.pages || []);
      allowedKeys.forEach((key) => checked ? pages.add(key) : pages.delete(key));
      patchUser(userId, { pages: [...pages] });
    } else patchUser(userId, Object.fromEntries(allowedKeys.map((key) => [key, checked])));
  }

  function permissionPayload(current) {
    if (isAdministrativeRole(current.role)) return {};
    return {
      pages: current.pages || [],
      ...Object.fromEntries(Object.keys(GENERAL_PERMISSION_LABELS).map((key) => [key, Boolean(current[key])])),
      ...Object.fromEntries(ACTION_PERMISSIONS.map((key) => [key, Boolean(current[key])])),
    };
  }

  async function createManagedAccount() {
    const phone = normalizeAccountPhone(newAccount.phone);
    if (!newAccount.fullName.trim()) return setMessage({ type: "error", text: "اكتب اسم مستخدم الحساب." });
    if (!phone) return setMessage({ type: "error", text: "اكتب رقم الهاتف بالصيغة الدولية، مثال: +9665XXXXXXXX." });
    if (newAccount.temporaryPassword.length < 10) return setMessage({ type: "error", text: "كلمة السر المؤقتة يجب ألا تقل عن 10 أحرف." });
    if (!canAssignRole(currentProfile.role, newAccount.role)) return setMessage({ type: "error", text: "لا يسمح دورك بإنشاء هذا النوع من الحسابات." });
    setMessage({ type: "", text: "" });
    setCreatingAccount(true);
    const result = await supabase.functions.invoke("admin-manage-user", { body: {
      action: "create",
      full_name: newAccount.fullName.trim(),
      phone,
      temporary_password: newAccount.temporaryPassword,
      role: newAccount.role,
    } });
    if (result.error || !result.data?.ok) {
      setCreatingAccount(false);
      return setMessage({ type: "error", text: result.data?.error || result.error?.message || "تعذر إنشاء الحساب المُدار." });
    }
    await load();
    setNewAccount({ fullName: "", phone: "", temporaryPassword: "", role: MANAGER_ASSIGNABLE_ROLES[0] });
    setCreatingAccount(false);
    setMessage({ type: "success", text: "تم إنشاء الحساب. سلّم كلمة السر المؤقتة للمستخدم عبر قناة آمنة؛ سيُطلب تغييرها عند أول دخول." });
  }

  async function savePermissions(userId) {
    const current = pending[userId];
    if (!current) return;
    setMessage({ type: "", text: "" });
    setSavingUserId(userId);
    const mutationResult = await supabase.rpc("admin_update_profile", {
      target_user_id: userId,
      target_role: current.role,
      target_permissions: permissionPayload(current),
      target_status: current.status || "active",
    });
    console.info("[permissions] mutationResult", mutationResult);
    if (mutationResult.error) {
      setSavingUserId(null);
      return setMessage({ type: "error", text: mutationResult.error.message });
    }
    if (!mutationResult.data?.ok) {
      setSavingUserId(null);
      return setMessage({ type: "error", text: mutationResult.data?.error || "تعذر حفظ الصلاحيات." });
    }
    await load();
    setSavingUserId(null);
    setMessage({ type: "success", text: "تم حفظ الدور والصلاحيات بأمان." });
  }

  async function updateManagedPhone(profileId) {
    const phone = normalizeAccountPhone(pending[profileId]?.phone);
    const reason = (phoneReasons[profileId] || "").trim();
    if (!phone) return setMessage({ type: "error", text: "اكتب رقم الهاتف بالصيغة الدولية." });
    if (!reason) return setMessage({ type: "error", text: "اكتب سبب تغيير رقم الدخول لسجل التدقيق." });
    setMessage({ type: "", text: "" });
    setUpdatingPhoneUserId(profileId);
    const result = await supabase.functions.invoke("admin-manage-user", { body: { action: "update_phone", user_id: profileId, phone, reason } });
    if (result.error || !result.data?.ok) {
      setUpdatingPhoneUserId(null);
      return setMessage({ type: "error", text: result.data?.error || result.error?.message || "تعذر تغيير رقم الدخول." });
    }
    await load();
    setPhoneReasons((previous) => ({ ...previous, [profileId]: "" }));
    setUpdatingPhoneUserId(null);
    setMessage({ type: "success", text: "تم تغيير رقم الدخول وتسجيل العملية في سجل التدقيق." });
  }

  async function saveEmployeeLink(profileId) {
    const current = pending[profileId];
    const reason = (linkReasons[profileId] || "").trim();
    if (!reason) return setMessage({ type: "error", text: "اكتب سبب ربط هوية الحساب بالموظف." });
    setMessage({ type: "", text: "" });
    setLinkingUserId(profileId);
    const mutationResult = await supabase.rpc("admin_link_profile_employee", {
      target_user_id: profileId,
      target_employee_id: current?.employee_id || null,
      reason,
    });
    console.info("[profiles:employee-link] mutationResult", mutationResult);
    if (mutationResult.error || !mutationResult.data?.ok) {
      setLinkingUserId(null);
      return setMessage({ type: "error", text: mutationResult.error?.message || "تعذر حفظ ربط الموظف بالحساب." });
    }
    await Promise.all([load(), refresh("employees")]);
    setLinkReasons((previous) => ({ ...previous, [profileId]: "" }));
    setLinkingUserId(null);
    setMessage({ type: "success", text: "تم حفظ رابط الهوية المعياري وتسجيله في سجل التدقيق." });
  }

  if (!profiles) return <Empty text="جارِ التحميل..." />;
  const allOpen = PERMISSION_SECTIONS.every((section) => openSections[section.id]);
  return <div>
    <SectionTitle eyebrow="الهوية والوصول" title="الفريق والصلاحيات" icon={<ShieldCheck size={14} />} description="إدارة الأدوار والصلاحيات وفق تسلسل إداري محمي ومسجل بالكامل." />
    {message.text && <Banner type={message.type}>{message.text}</Banner>}
    <Card className="managed-account-create">
      <div><strong>إنشاء حساب مُدار</strong><p>لا يوجد تسجيل ذاتي. أنشئ الحساب برقم دولي وكلمة سر مؤقتة؛ ولا تُحفظ كلمة السر داخل قاعدة بيانات التطبيق.</p></div>
      <div className="team-controls">
        <Field label="الاسم"><Input value={newAccount.fullName} onChange={(event) => setNewAccount((current) => ({ ...current, fullName: event.target.value }))} /></Field>
        <Field label="رقم الهاتف"><Input value={newAccount.phone} onChange={(event) => setNewAccount((current) => ({ ...current, phone: event.target.value }))} placeholder="+9665XXXXXXXX" /></Field>
        <Field label="كلمة السر المؤقتة"><Input type="password" value={newAccount.temporaryPassword} onChange={(event) => setNewAccount((current) => ({ ...current, temporaryPassword: event.target.value }))} autoComplete="new-password" /></Field>
        <Field label="الدور"><Select value={newAccount.role} onChange={(event) => setNewAccount((current) => ({ ...current, role: event.target.value }))}>{Object.entries(ROLES).filter(([roleKey]) => canAssignRole(currentProfile.role, roleKey)).map(([roleKey, role]) => <option key={roleKey} value={roleKey}>{role.label}</option>)}</Select></Field>
      </div>
      <Btn disabled={creatingAccount} onClick={createManagedAccount}>{creatingAccount ? "جارِ إنشاء الحساب..." : "إنشاء الحساب"}</Btn>
    </Card>
    <div className="permissions-toolbar">
      <Btn variant="ghost" onClick={() => setOpenSections(Object.fromEntries(PERMISSION_SECTIONS.map((section) => [section.id, true])))}>فتح الكل</Btn>
      <Btn variant="ghost" onClick={() => setOpenSections({})}>إغلاق الكل</Btn>
      <span>{allOpen ? "كل أقسام الصلاحيات مفتوحة" : "افتح القسم المطلوب لتقليل الزحام"}</span>
    </div>
    <div className="team-grid">
      {profiles.map((profile) => {
        const current = pending[profile.id] || { role: profile.role, status: profile.status || "active", employee_id: profile.employee_id || "", phone: profile.phone || "", ...permissionsForProfile(profile) };
        const protectionReason = identityProtectionReason(currentProfile, profile);
        const protectedFields = Boolean(protectionReason);
        const automaticAccess = isAdministrativeRole(current.role);
        return <Card className={`team-card role-${current.role}`} key={profile.id}>
          <div className="team-card-head">
            <div className="team-identity"><div className="team-avatar">{(profile.full_name || profile.email || "؟").trim().charAt(0)}</div><div><strong>{profile.full_name || "بدون اسم"}</strong><span>{profile.phone || profile.email || `${profile.id.slice(0, 8)}…`}{profile.must_change_password ? " — كلمة سر مؤقتة" : ""}</span></div></div>
            <span className={`role-badge ${current.role}`}>{ROLES[current.role]?.label || current.role}</span>
          </div>
          <div className="team-controls">
            <Field label="الدور">
              <Select disabled={protectedFields} value={current.role} onChange={(event) => patchUser(profile.id, { role: event.target.value, ...permissionsForProfile({ role: event.target.value, permissions: {} }) })}>
                {Object.entries(ROLES).map(([roleKey, role]) => <option key={roleKey} value={roleKey} disabled={!canAssignRole(currentProfile.role, roleKey)}>{role.label}</option>)}
              </Select>
            </Field>
            <Field label="حالة الحساب">
              <Select disabled={protectedFields} value={current.status || "active"} onChange={(event) => patchUser(profile.id, { status: event.target.value })}>
                <option value="active">نشط</option><option value="suspended">موقوف</option>
              </Select>
            </Field>
          </div>
          {protectionReason && <div className="protected-note"><ShieldCheck size={17} /><span><strong>حقول محمية</strong>{protectionReason}</span></div>}
          {current.role === "owner" && <div className="automatic-access-note"><ShieldCheck size={18} /><span><strong>صلاحيات مالك النظام تلقائية</strong>يمتلك جميع صلاحيات النظام من الدور مباشرة ولا يعتمد على Checkboxes مخزنة.</span></div>}
          {current.role === "manager" && <div className="automatic-access-note manager"><ShieldCheck size={18} /><span><strong>صلاحيات تشغيلية كاملة</strong>مدير النظام لا يعتمد على Checkboxes، ولا يمكن لمدير آخر إدارته أو تعديل Audit Log.</span></div>}
          {!protectedFields && profile.phone && <div className="identity-link-box">
            <strong>رقم تسجيل الدخول</strong><p>تغيير الرقم يحدّث حساب المصادقة والملف معًا، ويحتاج سببًا موثقًا.</p>
            <Field label="رقم الهاتف"><Input value={current.phone || ""} onChange={(event) => patchUser(profile.id, { phone: event.target.value })} /></Field>
            <Field label="سبب التغيير"><Input value={phoneReasons[profile.id] || ""} onChange={(event) => setPhoneReasons((previous) => ({ ...previous, [profile.id]: event.target.value }))} /></Field>
            <Btn variant="ghost" disabled={updatingPhoneUserId === profile.id || normalizeAccountPhone(current.phone) === profile.phone} onClick={() => updateManagedPhone(profile.id)}>{updatingPhoneUserId === profile.id ? "جارِ التحديث..." : "تحديث رقم الدخول"}</Btn>
          </div>}
          {currentProfile.role === "owner" && <div className="identity-link-box">
            <strong>ربط الحساب بموظف</strong>
            <p>هذا هو الرابط المعياري المستخدم في تأكيد هوية مستلم العهدة، ولا يعتمد على الاسم أو الهاتف.</p>
            <Field label="الموظف المرتبط">
              <Select value={current.employee_id || ""} onChange={(event) => patchUser(profile.id, { employee_id: event.target.value })}>
                <option value="">لا يوجد موظف مرتبط</option>
                {(employees || []).filter((employee) => employee.status === "active").map((employee) => {
                  const linkedElsewhere = profiles.some((candidate) => candidate.id !== profile.id && candidate.employee_id === employee.id);
                  return <option key={employee.id} value={employee.id} disabled={linkedElsewhere}>{employee.full_name}{linkedElsewhere ? " — مرتبط بحساب آخر" : ""}</option>;
                })}
              </Select>
            </Field>
            <Field label="سبب الربط أو التغيير">
              <Input value={linkReasons[profile.id] || ""} onChange={(event) => setLinkReasons((previous) => ({ ...previous, [profile.id]: event.target.value }))} placeholder="سبب موثق لسجل التدقيق" />
            </Field>
            <Btn variant="ghost" disabled={linkingUserId === profile.id || (current.employee_id || "") === (profile.employee_id || "")} onClick={() => saveEmployeeLink(profile.id)}>{linkingUserId === profile.id ? "جارِ حفظ الربط..." : "حفظ ربط الموظف"}</Btn>
          </div>}
          {!automaticAccess && <div className="permission-accordion-list">
            {PERMISSION_SECTIONS.map((section) => {
              const enabledCount = section.keys.filter((key) => isChecked(current, section, key)).length;
              const open = Boolean(openSections[section.id]);
              return <section className="permission-accordion" key={section.id}>
                <button type="button" className="permission-accordion-toggle" aria-expanded={open} onClick={() => setOpenSections((previous) => ({ ...previous, [section.id]: !open }))}>
                  <span><ChevronDown size={16} className={open ? "open" : ""} />{section.label}</span><b>{enabledCount}/{section.keys.length}</b>
                </button>
                {open && <div className="permission-accordion-body">
                  <div className="permission-section-actions"><button type="button" onClick={() => setSection(profile.id, section, true)}>تحديد الكل داخل القسم</button><button type="button" onClick={() => setSection(profile.id, section, false)}>إزالة الكل داخل القسم</button></div>
                  <div className="permission-options">
                    {section.keys.map((key) => {
                      const allowed = itemAllowed(current.role, section, key);
                      const label = section.type === "page" ? PAGE_LABELS[key] : (GENERAL_PERMISSION_LABELS[key] || PERMISSION_LABELS[key] || key);
                      return <label className={!allowed ? "disabled" : ""} key={key} title={!allowed ? "هذه الصلاحية محمية لهذا الدور بواسطة RLS" : ""}>
                        <input type="checkbox" disabled={!allowed} checked={isChecked(current, section, key)} onChange={(event) => setPermission(profile.id, section, key, event.target.checked)} /><span>{label}</span>{!allowed && <small>محمي</small>}
                      </label>;
                    })}
                  </div>
                </div>}
              </section>;
            })}
          </div>}
          <div className="team-card-actions">
            <Btn disabled={protectedFields || savingUserId === profile.id} onClick={() => savePermissions(profile.id)}>{savingUserId === profile.id ? "جارِ الحفظ..." : "حفظ الدور والصلاحيات"}</Btn>
          </div>
        </Card>;
      })}
    </div>
  </div>;
}
