import React, { useState, useEffect, useMemo, useCallback } from "react";
import { supabase } from "./supabaseClient";
import {
  LayoutDashboard, Package, Layers, Factory, ShoppingCart, Truck, Users,
  BarChart3, Plus, Trash2, AlertCircle, CheckCircle2, Wallet, Boxes, LogOut,
  CalendarClock, ShieldCheck, Pencil, X, ReceiptText, ClipboardList,
  BriefcaseBusiness, FolderOpen, UserRoundCog, BadgeDollarSign, HardHat, ScrollText,
} from "lucide-react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Legend,
} from "recharts";
import { ACTION_PERMISSIONS, actionPermissions } from "./v22/shared";
import { ProjectsTab, ProjectFilesHub } from "./v22/projects";
import { EmployeesTab, PayrollTab } from "./v22/payroll";
import { DailyLaborTab } from "./v22/dailyLabor";
import { AuditLogTab, PERMISSION_LABELS } from "./v22/audit";
import { demoData, demoProfile } from "./v22/demoData";
import { PROJECT_FILES_TABLE } from "./v22/fileTypes";
import { syncMutation } from "./v22/mutations";

const V22_DEMO = (import.meta.env.DEV || import.meta.env.VITE_ENABLE_DEMO === "true") && new URLSearchParams(window.location.search).get("demo") === "v22";

/* ---------------------------------- ثيم ---------------------------------- */
const C = {
  bg: "#1C1916", panel: "#242019", panelAlt: "#2C2620", border: "#3D3527",
  wood: "#B8703A", woodDark: "#8C5527", brass: "#D9A441",
  text: "#EDE6D8", muted: "#A69C8A", green: "#7FA35C", red: "#C1543A",
};

const num = (v) => { const n = parseFloat(v); return isFinite(n) ? n : 0; };
const fmt = (n) => (isFinite(n) ? n : 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const todayStr = () => new Date().toISOString().slice(0, 10);

const ROLES = {
  manager: { label: "المدير", desc: "كل الصلاحيات: عرض، تعديل، حذف، وكل التقارير" },
  accountant: { label: "المحاسب", desc: "إضافة المنتجات والعمليات المالية بدون تعديل أو حذف المنتجات" },
  production: { label: "موظف الإنتاج", desc: "تسجيل أوامر الإنتاج فقط" },
};
const SIGNUP_ROLES = ["accountant", "production"];
const NAV_BY_ROLE = {
  manager: ["dashboard", "projects", "projectFiles", "inventory", "purchases", "expenses", "materials", "products", "production", "sales", "rentals", "suppliers", "customers", "employees", "payroll", "dailyLabor", "reports", "auditLog", "team"],
  accountant: ["projects", "projectFiles", "inventory", "purchases", "expenses", "materials", "products", "production", "sales", "rentals", "suppliers", "customers", "employees", "payroll", "dailyLabor"],
  production: ["projects", "projectFiles", "inventory", "production"],
};
const ALL_PAGE_IDS = ["dashboard", "projects", "projectFiles", "inventory", "purchases", "expenses", "materials", "products", "production", "sales", "rentals", "suppliers", "customers", "employees", "payroll", "dailyLabor", "reports", "auditLog", "team"];
const PAGE_LABELS = {
  projects: "المشاريع", projectFiles: "ملفات المشاريع", employees: "الموظفون", payroll: "المرتبات", dailyLabor: "العمالة اليومية", auditLog: "سجل التدقيق",
  dashboard: "لوحة التحكم", inventory: "المخزون", purchases: "المشتريات", expenses: "المصروفات", materials: "المواد الخام", products: "المنتجات والتكلفة",
  production: "أوامر الإنتاج", sales: "المبيعات", rentals: "الإيجارات",
  suppliers: "الموردين", customers: "العملاء", reports: "التقارير", team: "الفريق والصلاحيات",
};
function permissionsForProfile(profile) {
  const actions = actionPermissions(profile);
  if (profile?.role === "manager") return {
    pages: ALL_PAGE_IDS,
    can_delete: true,
    view_financials: true,
    can_create_products: true,
    can_edit_products: true, ...actions,
  };
  const saved = profile?.permissions || {};
  const isAccountant = profile?.role === "accountant";
  const legacyPages = Array.isArray(saved.pages) && saved.pages.length ? saved.pages : (NAV_BY_ROLE[profile?.role] || []);
  const modulePages = [actions.projects_view && "projects", actions.project_files_view && "projectFiles", actions.payroll_view && "payroll", actions.daily_labor_view && "dailyLabor"].filter(Boolean);
  if (profile?.role === "accountant") modulePages.push("employees");
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

const TABLES = {
  materials: "materials",
  materialPurchases: "material_purchases",
  products: "products",
  productionOrders: "production_orders",
  sales: "sales",
  rentals: "rentals",
  suppliers: "suppliers",
  supplierPayments: "supplier_payments",
  customers: "customers",
  customerReceipts: "customer_receipts",
  expenses: "expenses",
  projects: "projects",
  projectFiles: PROJECT_FILES_TABLE,
  projectActivities: "project_activities",
  employees: "employees",
  payroll: "payroll",
  dailyLabor: "daily_labor",
  projectCosts: "project_costs",
  auditLog: "audit_log",
};
const EMPTY_DATA = {
  materials: [], materialPurchases: [], products: [], productionOrders: [],
  sales: [], rentals: [], suppliers: [], supplierPayments: [], customers: [], customerReceipts: [], expenses: [],
  projects: [], projectFiles: [], projectActivities: [], employees: [], payroll: [], dailyLabor: [], projectCosts: [], auditLog: [],
};

async function fetchTableRows(key, table) {
  let fetchResult;
  if (key === "projects") fetchResult = await supabase.rpc("get_projects_visible");
  else if (key === "payroll") fetchResult = await supabase.rpc("get_payroll_visible");
  else {
    fetchResult = await supabase.from(table).select("*").order("created_at", { ascending: true });
    // Backward-compatible fallback until the project_files created_at migration is applied.
    if (key === "projectFiles" && fetchResult.error?.code === "42703") {
      console.warn("[ProjectFiles] created_at is missing; falling back to uploaded_at", fetchResult.error);
      fetchResult = await supabase.from(PROJECT_FILES_TABLE).select("*").order("uploaded_at", { ascending: true });
    }
  }
  if (key === "projectFiles") console.info("[ProjectFiles] fetchResult", { table: PROJECT_FILES_TABLE, fetchResult });
  if (fetchResult.error) console.error(`[NEXTEP] Failed to fetch ${table}`, fetchResult.error);
  return fetchResult;
}

/* ------------------------------ دوال الحسابات ------------------------------ */
function materialConsumedQty(materialId, data) {
  let total = 0;
  for (const o of data.productionOrders) {
    const p = data.products.find((x) => x.id === o.product_id);
    if (!p) continue;
    const row = (p.bom || []).find((r) => r.material_id === materialId);
    if (row) total += row.qty * o.qty * (1 + num(o.waste_percentage) / 100);
  }
  return total;
}
function materialPurchasedQty(materialId, data) {
  return data.materialPurchases.filter((p) => p.material_id === materialId).reduce((s, p) => s + p.qty, 0);
}
function materialStock(materialId, data) {
  const m = data.materials.find((x) => x.id === materialId);
  if (!m) return 0;
  return num(m.initial_stock) + materialPurchasedQty(materialId, data) - materialConsumedQty(materialId, data);
}
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
  return data.sales.filter((s) => s.product_id === productId).reduce((s, o) => s + o.qty, 0);
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
  return data.supplierPayments.filter((p) => p.supplier_id === supplierId).reduce((s, p) => s + p.amount, 0);
}
function supplierBalance(supplierId, data) { return supplierPurchaseTotal(supplierId, data) - supplierPaymentTotal(supplierId, data); }
function customerSaleTotal(customerId, data) {
  return data.sales.filter((s) => s.customer_id === customerId).reduce((s, o) => s + o.total, 0);
}
function customerReceiptTotal(customerId, data) {
  return data.customerReceipts.filter((r) => r.customer_id === customerId).reduce((s, r) => s + r.amount, 0);
}
function customerRentalTotal(customerId, data) {
  return data.rentals.filter((r) => r.customer_id === customerId).reduce((s, r) => s + r.rental_fee, 0);
}
function customerBalance(customerId, data) { return customerSaleTotal(customerId, data) + customerRentalTotal(customerId, data) - customerReceiptTotal(customerId, data); }

/* ------------------------------- عناصر عامة ------------------------------- */
function Card({ children, style, ...rest }) {
  return <div style={{ background: C.panel, border: `1px solid ${C.border}`, borderRadius: 12, padding: 18, ...style }} {...rest}>{children}</div>;
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
    danger: { background: "transparent", color: C.red, border: `1px solid ${C.red}55` },
  };
  return <button {...rest} disabled={rest.disabled} style={{ display: "inline-flex", alignItems: "center", gap: 6, border: "none", borderRadius: 8, padding: "9px 16px", fontFamily: "Tajawal, sans-serif", fontWeight: 700, fontSize: 13.5, cursor: rest.disabled ? "default" : "pointer", opacity: rest.disabled ? 0.6 : 1, ...styles[variant], ...(rest.style || {}) }}>{children}</button>;
}
function SectionTitle({ eyebrow, title, icon }) {
  return (
    <div style={{ marginBottom: 18 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, color: C.brass, fontSize: 12.5, fontWeight: 700, letterSpacing: 0.5, marginBottom: 4 }}>
        {icon}<span>{eyebrow}</span>
      </div>
      <h2 style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 22, color: C.text, margin: 0 }}>{title}</h2>
    </div>
  );
}
function Banner({ type = "error", children }) {
  const isErr = type === "error";
  return (
    <div style={{ display: "flex", alignItems: "flex-start", gap: 8, background: isErr ? `${C.red}1a` : `${C.green}1a`, border: `1px solid ${isErr ? C.red : C.green}55`, color: isErr ? "#E28468" : "#9CC17A", borderRadius: 8, padding: "10px 12px", fontSize: 13, marginTop: 10 }}>
      {isErr ? <AlertCircle size={16} style={{ flexShrink: 0, marginTop: 2 }} /> : <CheckCircle2 size={16} style={{ flexShrink: 0, marginTop: 2 }} />}
      <span>{children}</span>
    </div>
  );
}
function Table({ headers, children }) {
  return (
    <div style={{ overflowX: "auto" }}>
      <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13.5 }}>
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

/* ----------------------------- شاشة الدخول والتسجيل ----------------------------- */
function AuthGate() {
  const [mode, setMode] = useState("login");
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [role, setRole] = useState(SIGNUP_ROLES[0]);
  const [err, setErr] = useState("");
  const [info, setInfo] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit() {
    setErr(""); setInfo("");
    if (!email.trim() || !password) return setErr("اكتب الإيميل وكلمة السر");
    setBusy(true);
    try {
      if (mode === "login") {
        const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (error) setErr(error.message);
      } else {
        if (!fullName.trim()) { setBusy(false); return setErr("اكتب اسمك"); }
        const { data: signData, error } = await supabase.auth.signUp({ email: email.trim(), password });
        if (error) { setBusy(false); return setErr(error.message); }
        const userId = signData?.user?.id;
        if (userId) {
          const profileMutationResult = await supabase.from("profiles").insert({ id: userId, full_name: fullName.trim(), role });
          console.info("[profiles:signup] mutationResult", profileMutationResult);
          const profErr = profileMutationResult.error;
          if (profErr) setErr("تم إنشاء الحساب لكن حصل خطأ في حفظ الصفة: " + profErr.message);
        }
        if (!signData?.session) {
          setInfo("تم إنشاء الحساب. لو النظام محتاج تأكيد إيميل، افتح الإيميل بتاعك وأكّده ثم سجّل دخول.");
        }
      }
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
        <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
          <button onClick={() => setMode("login")} style={{ flex: 1, padding: "8px", borderRadius: 8, border: "none", cursor: "pointer", background: mode === "login" ? C.wood : "transparent", color: mode === "login" ? "#fff" : C.muted, fontWeight: 700 }}>تسجيل الدخول</button>
          <button onClick={() => setMode("signup")} style={{ flex: 1, padding: "8px", borderRadius: 8, border: "none", cursor: "pointer", background: mode === "signup" ? C.wood : "transparent", color: mode === "signup" ? "#fff" : C.muted, fontWeight: 700 }}>حساب جديد</button>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          {mode === "signup" && (
            <Field label="الاسم">
              <Input value={fullName} onChange={(e) => setFullName(e.target.value)} />
            </Field>
          )}
          <Field label="الإيميل">
            <Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
          </Field>
          <Field label="كلمة السر">
            <Input type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
          </Field>
          {mode === "signup" && (
            <Field label="صفتك في المصنع">
              <Select value={role} onChange={(e) => setRole(e.target.value)}>
                {SIGNUP_ROLES.map((k) => <option key={k} value={k}>{ROLES[k].label}</option>)}
              </Select>
            </Field>
          )}
        </div>

        <div style={{ marginTop: 16 }}>
          <Btn onClick={submit} disabled={busy} style={{ width: "100%", justifyContent: "center" }}>
            {busy ? "..." : mode === "login" ? "دخول" : "إنشاء الحساب"}
          </Btn>
        </div>
        {err && <Banner type="error">{err}</Banner>}
        {info && <Banner type="success">{info}</Banner>}
      </Card>
      <div style={{ fontSize: 11.5, color: C.muted, marginTop: 16, maxWidth: 340, textAlign: "center" }}>
        كل من يسجّل حساب جديد يظهر لباقي المستخدمين تلقائيًا، والبيانات مشتركة بين الجميع.
      </div>
    </div>
  );
}

/* --------------------------------- التطبيق --------------------------------- */
export default function App() {
  const [session, setSession] = useState(V22_DEMO ? { user: { id: demoProfile.id } } : undefined);
  const [profile, setProfile] = useState(V22_DEMO ? demoProfile : undefined);
  const [data, setData] = useState(V22_DEMO ? demoData : null);
  const [tab, setTab] = useState(V22_DEMO ? "projects" : null);

  useEffect(() => {
    if (V22_DEMO) return;
    supabase.auth.getSession().then(({ data: { session } }) => setSession(session));
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => setSession(session));
    return () => sub.subscription.unsubscribe();
  }, []);

  const fetchProfile = useCallback(async (userId) => {
    const { data: rows } = await supabase.from("profiles").select("*").eq("id", userId).limit(1);
    setProfile(rows && rows.length ? rows[0] : null);
  }, []);

  useEffect(() => {
    if (V22_DEMO) return;
    if (session === undefined) return;
    if (!session) { setProfile(null); return; }
    fetchProfile(session.user.id);
  }, [session, fetchProfile]);

  const refetchTable = useCallback(async (key) => {
    if (V22_DEMO) return;
    const table = TABLES[key];
    const fetchResult = await fetchTableRows(key, table);
    if (!fetchResult.error) setData((prev) => ({ ...(prev || EMPTY_DATA), [key]: fetchResult.data || [] }));
    return fetchResult;
  }, []);

  useEffect(() => {
    if (V22_DEMO) return;
    if (!session) return;
    (async () => {
      const entries = await Promise.all(
        Object.entries(TABLES).map(async ([key, table]) => {
          const fetchResult = await fetchTableRows(key, table);
          return [key, fetchResult.error ? [] : (fetchResult.data || [])];
        })
      );
      setData(Object.fromEntries(entries));
    })();

    const channel = supabase.channel("factory-realtime");
    Object.entries(TABLES).forEach(([key, table]) => {
      channel.on("postgres_changes", { event: "*", schema: "public", table }, () => refetchTable(key));
    });
    channel.subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [session, refetchTable]);

  if (session === undefined || (session && profile === undefined)) {
    return <LoadingScreen text="جارِ التحميل..." />;
  }
  if (!session) return <AuthGate />;
  if (profile === null) return <LoadingScreen text="جارِ إعداد حسابك..." />;
  if (!data) return <LoadingScreen text="جارِ تحميل البيانات..." />;

  const role = profile.role;
  const permissions = permissionsForProfile(profile);
  const activeTab = permissions.pages.includes(tab) ? tab : permissions.pages[0];
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
    { id: "sales", label: "المبيعات", icon: ShoppingCart },
    { id: "rentals", label: "الإيجارات", icon: CalendarClock },
    { id: "suppliers", label: "الموردين", icon: Truck },
    { id: "customers", label: "العملاء", icon: Users },
    { id: "employees", label: "الموظفون", icon: UserRoundCog },
    { id: "payroll", label: "المرتبات", icon: BadgeDollarSign },
    { id: "dailyLabor", label: "العمالة اليومية", icon: HardHat },
    { id: "reports", label: "التقارير", icon: BarChart3 },
    { id: "auditLog", label: "سجل التدقيق", icon: ScrollText },
    { id: "team", label: "الفريق والصلاحيات", icon: ShieldCheck },
  ];
  const NAV = ALL_NAV.filter((n) => permissions.pages.includes(n.id));

  async function insertRow(key, payload) {
    const mutationResult = await supabase.from(TABLES[key]).insert(payload);
    const result = await syncMutation({ scope: `${key}:create`, mutationResult, refetch: () => refetchTable(key) });
    return result.error?.message || null;
  }
  async function deleteRow(key, id) {
    const mutationResult = await supabase.from(TABLES[key]).delete().eq("id", id);
    const result = await syncMutation({ scope: `${key}:delete`, mutationResult, refetch: () => refetchTable(key) });
    return result.error?.message || null;
  }
  async function updateRow(key, id, patch) {
    const mutationResult = await supabase.from(TABLES[key]).update(patch).eq("id", id);
    const result = await syncMutation({ scope: `${key}:update`, mutationResult, refetch: () => refetchTable(key) });
    return result.error?.message || null;
  }

  return (
    <div dir="rtl" style={{ fontFamily: "Tajawal, sans-serif", background: C.bg, minHeight: "100vh", display: "flex", color: C.text }}>
      <div style={{ width: 235, flexShrink: 0, background: "linear-gradient(180deg, #191612 0%, #211B15 100%)", borderLeft: `1px solid ${C.border}`, padding: "20px 12px", display: "flex", flexDirection: "column", gap: 4, position: "sticky", top: 0, height: "100vh", overflowY: "auto" }}>
        <div style={{ padding: "0 8px 18px 8px" }}>
          <img src="/logo.png" alt="NEXTEP" style={{ width: 195, height: 82, objectFit: "contain", display: "block", margin: "0 auto 12px" }} />
          <div style={{ fontSize: 11.5, color: C.muted, marginTop: 2 }}>{profile.full_name}</div>
          <div style={{ fontSize: 11.5, color: C.brass, marginTop: 2, fontWeight: 700 }}>{ROLES[role]?.label}</div>
        </div>
        {NAV.map((n) => {
          const Icon = n.icon;
          const active = activeTab === n.id;
          return (
            <button key={n.id} onClick={() => setTab(n.id)} style={{ display: "flex", alignItems: "center", gap: 10, padding: "10px 12px", borderRadius: 8, border: "none", cursor: "pointer", background: active ? C.wood : "transparent", color: active ? "#fff" : C.muted, fontFamily: "Tajawal, sans-serif", fontWeight: active ? 700 : 500, fontSize: 14, textAlign: "right", width: "100%" }}>
              <Icon size={17} />{n.label}
            </button>
          );
        })}
        <button onClick={() => supabase.auth.signOut()} style={{ marginTop: "auto", display: "flex", alignItems: "center", gap: 8, background: "none", border: `1px solid ${C.border}`, borderRadius: 8, color: C.muted, fontSize: 13, padding: "8px 10px", cursor: "pointer", fontFamily: "Tajawal, sans-serif" }}>
          <LogOut size={15} /> تسجيل الخروج
        </button>
      </div>

      <div style={{ flex: 1, padding: 28, maxWidth: 1180 }}>
        {activeTab === "dashboard" && <Dashboard data={data} />}
        {activeTab === "projects" && <ProjectsTab data={data} profile={profile} permissions={permissions} refresh={refetchTable} />}
        {activeTab === "projectFiles" && <ProjectFilesHub data={data} permissions={permissions} refresh={refetchTable} />}
        {activeTab === "inventory" && <InventoryTab data={data} />}
        {activeTab === "purchases" && <PurchasesTab data={data} insertRow={insertRow} deleteRow={deleteRow} canDelete={permissions.can_delete} />}
        {activeTab === "expenses" && <ExpensesTab data={data} insertRow={insertRow} deleteRow={deleteRow} canDelete={permissions.can_delete} />}
        {activeTab === "materials" && <MaterialsTab data={data} canDelete={permissions.can_delete} insertRow={insertRow} deleteRow={deleteRow} updateRow={updateRow} />}
        {activeTab === "products" && <ProductsTab data={data} canCreate={permissions.can_create_products} canEdit={permissions.can_edit_products} canDelete={permissions.can_delete} hideProfitInfo={!permissions.view_financials} insertRow={insertRow} deleteRow={deleteRow} updateRow={updateRow} />}
        {activeTab === "production" && <ProductionTab data={data} insertRow={insertRow} updateRow={updateRow} deleteRow={deleteRow} canManage={role === "manager"} />}
        {activeTab === "sales" && <SalesTab data={data} insertRow={insertRow} updateRow={updateRow} deleteRow={deleteRow} canManage={role === "manager"} />}
        {activeTab === "rentals" && <RentalsTab data={data} insertRow={insertRow} updateRow={updateRow} deleteRow={deleteRow} canManage={role === "manager"} />}
        {activeTab === "suppliers" && <SuppliersTab data={data} insertRow={insertRow} updateRow={updateRow} deleteRow={deleteRow} canManage={role === "manager"} />}
        {activeTab === "customers" && <CustomersTab data={data} insertRow={insertRow} updateRow={updateRow} deleteRow={deleteRow} canManage={role === "manager"} />}
        {activeTab === "employees" && role !== "production" && <EmployeesTab data={data} profile={profile} refresh={refetchTable} />}
        {activeTab === "payroll" && permissions.payroll_view && <PayrollTab data={data} profile={profile} permissions={permissions} refresh={refetchTable} />}
        {activeTab === "dailyLabor" && permissions.daily_labor_view && <DailyLaborTab data={data} profile={profile} permissions={permissions} refresh={refetchTable} />}
        {activeTab === "reports" && permissions.view_financials && <ReportsTab data={data} />}
        {activeTab === "auditLog" && permissions.audit_log_view && <AuditLogTab data={data} />}
        {activeTab === "team" && <TeamTab />}
      </div>
    </div>
  );
}

function LoadingScreen({ text }) {
  return (
    <div style={{ minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center", background: C.bg, color: C.muted, fontFamily: "Tajawal, sans-serif" }}>
      {text}
    </div>
  );
}

/* --------------------------------- Dashboard -------------------------------- */
function Dashboard({ data }) {
  const stats = useMemo(() => {
    const materialsValue = data.materials.reduce((s, m) => s + materialStock(m.id, data) * m.unit_cost, 0);
    const finishedValue = data.products.reduce((s, p) => s + finishedStock(p.id, data) * (avgProductionUnitCost(p.id, data) || productUnitCost(p, data)), 0);
    const totalSuppliers = data.suppliers.reduce((s, sup) => s + supplierBalance(sup.id, data), 0);
    const totalCustomers = data.customers.reduce((s, c) => s + customerBalance(c.id, data), 0);
    const monthKey = todayStr().slice(0, 7);
    const today = todayStr();
    const ordersThisMonth = data.productionOrders.filter((o) => (o.order_date || "").slice(0, 7) === monthKey).length;
    const todayProduction = data.productionOrders.filter((o) => o.order_date === today).reduce((sum, o) => sum + num(o.qty), 0);
    const todaySales = data.sales.filter((o) => o.sale_date === today).reduce((sum, o) => sum + num(o.total), 0);
    let revenue = 0, cogs = 0;
    for (const sale of data.sales) {
      revenue += num(sale.total);
      const product = data.products.find((x) => x.id === sale.product_id);
      cogs += product ? num(sale.qty) * (avgProductionUnitCost(product.id, data) || productUnitCost(product, data)) : 0;
    }
    const lowMaterials = data.materials
      .map((m) => ({ ...m, stock: materialStock(m.id, data) }))
      .filter((m) => m.stock <= 10)
      .sort((a, b) => a.stock - b.stock);
    const lowProducts = data.products
      .map((p) => ({ ...p, stock: finishedStock(p.id, data) }))
      .filter((p) => p.stock <= 5)
      .sort((a, b) => a.stock - b.stock);
    const activeRentals = data.rentals.filter((r) => r.status === "active").length;
    return { materialsValue, finishedValue, totalSuppliers, totalCustomers, ordersThisMonth, todayProduction, todaySales, profit: revenue - cogs, lowMaterials, lowProducts, activeRentals };
  }, [data]);

  const chartData = data.products.slice(0, 8).map((p) => {
    const revenue = data.sales.filter((s) => s.product_id === p.id).reduce((sum, row) => sum + num(row.total), 0);
    const unitCost = avgProductionUnitCost(p.id, data) || productUnitCost(p, data);
    const cost = data.sales.filter((s) => s.product_id === p.id).reduce((sum, row) => sum + num(row.qty) * unitCost, 0);
    return { name: p.name.length > 10 ? p.name.slice(0, 10) + "…" : p.name, الإيراد: Math.round(revenue), التكلفة: Math.round(cost) };
  });

  const cards = [
    { label: "مبيعات اليوم", value: `${fmt(stats.todaySales)} ج.م`, color: C.green },
    { label: "إنتاج اليوم", value: `${fmt(stats.todayProduction)} وحدة`, color: C.brass },
    { label: "قيمة مخزون الخامات", value: `${fmt(stats.materialsValue)} ج.م`, color: C.brass },
    { label: "قيمة مخزون الإنتاج التام", value: `${fmt(stats.finishedValue)} ج.م`, color: C.wood },
    { label: "مستحق للموردين", value: `${fmt(stats.totalSuppliers)} ج.م`, color: C.red },
    { label: "مستحق من العملاء", value: `${fmt(stats.totalCustomers)} ج.م`, color: C.green },
    { label: "أوامر إنتاج هذا الشهر", value: stats.ordersThisMonth, color: C.brass },
    { label: "إيجارات نشطة", value: stats.activeRentals, color: C.wood },
    { label: "إجمالي المصروفات", value: `${fmt(stats.expensesTotal)} ج.م`, color: C.red },
    { label: "صافي الربح التقديري", value: `${fmt(stats.profit)} ج.م`, color: stats.profit >= 0 ? C.green : C.red },
  ];

  return (
    <div>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, flexWrap: "wrap", marginBottom: 18 }}>
        <SectionTitle eyebrow="نظرة عامة" title="لوحة التحكم التنفيذية" icon={<LayoutDashboard size={14} />} />
        <div style={{ color: C.muted, fontSize: 13, background: C.panel, border: `1px solid ${C.border}`, borderRadius: 10, padding: "9px 12px" }}>
          آخر تحديث: {new Date().toLocaleString("ar-EG")}
        </div>
      </div>

      {(stats.lowMaterials.length > 0 || stats.lowProducts.length > 0) && (
        <Card style={{ marginBottom: 18, borderColor: `${C.red}66`, background: `${C.red}10` }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, color: C.red, fontWeight: 800, marginBottom: 10 }}>
            <AlertCircle size={18} /> تنبيهات تحتاج تدخل
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))", gap: 10 }}>
            {stats.lowMaterials.slice(0, 5).map((m) => (
              <div key={`m-${m.id}`} style={{ background: C.bg, border: `1px solid ${C.border}`, borderRadius: 9, padding: 10 }}>
                <div style={{ fontWeight: 700 }}>{m.name}</div>
                <div style={{ color: m.stock <= 0 ? C.red : C.brass, fontSize: 12.5, marginTop: 3 }}>
                  خامة {m.stock <= 0 ? "نافدة" : "منخفضة"}: {fmt(m.stock)} {m.unit}
                </div>
              </div>
            ))}
            {stats.lowProducts.slice(0, 5).map((p) => (
              <div key={`p-${p.id}`} style={{ background: C.bg, border: `1px solid ${C.border}`, borderRadius: 9, padding: 10 }}>
                <div style={{ fontWeight: 700 }}>{p.name}</div>
                <div style={{ color: p.stock <= 0 ? C.red : C.brass, fontSize: 12.5, marginTop: 3 }}>
                  منتج {p.stock <= 0 ? "غير متوفر" : "قرب يخلص"}: {fmt(p.stock)} وحدة
                </div>
              </div>
            ))}
          </div>
        </Card>
      )}

      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(190px, 1fr))", gap: 14, marginBottom: 22 }}>
        {cards.map((c, i) => (
          <Card key={i} style={{ minHeight: 102, position: "relative", overflow: "hidden" }}>
            <div style={{ position: "absolute", insetInlineStart: 0, top: 0, bottom: 0, width: 4, background: c.color }} />
            <div style={{ fontSize: 12.5, color: C.muted, marginBottom: 8 }}>{c.label}</div>
            <div style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 21, color: c.color }}>{c.value}</div>
          </Card>
        ))}
      </div>

      <Card>
        <div style={{ fontSize: 13.5, color: C.muted, marginBottom: 12, fontWeight: 700 }}>الإيراد مقابل التكلفة لكل منتج</div>
        {chartData.length === 0 ? <Empty text="لا توجد بيانات مبيعات بعد لعرض الرسم البياني" /> : (
          <ResponsiveContainer width="100%" height={300}>
            <BarChart data={chartData}>
              <CartesianGrid stroke={C.border} strokeDasharray="3 3" />
              <XAxis dataKey="name" stroke={C.muted} fontSize={12} />
              <YAxis stroke={C.muted} fontSize={12} />
              <Tooltip contentStyle={{ background: C.panelAlt, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text }} />
              <Legend />
              <Bar dataKey="الإيراد" fill={C.brass} radius={[4, 4, 0, 0]} />
              <Bar dataKey="التكلفة" fill={C.wood} radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        )}
      </Card>
    </div>
  );
}


/* -------------------------------- Inventory --------------------------------- */
function InventoryTab({ data }) {
  const [search, setSearch] = useState("");
  const rawMaterials = data.materials.map((material) => {
    const stock = materialStock(material.id, data);
    return { ...material, stock, value: stock * num(material.unit_cost) };
  });
  const finishedProducts = data.products.map((product) => {
    const stock = finishedStock(product.id, data);
    const unitCost = avgProductionUnitCost(product.id, data) || productUnitCost(product, data);
    return { ...product, stock, unitCost, value: stock * unitCost };
  });
  const filteredMaterials = rawMaterials.filter((row) => row.name.toLowerCase().includes(search.toLowerCase()));
  const filteredProducts = finishedProducts.filter((row) => row.name.toLowerCase().includes(search.toLowerCase()));
  const rawValue = rawMaterials.reduce((sum, row) => sum + row.value, 0);
  const finishedValue = finishedProducts.reduce((sum, row) => sum + row.value, 0);
  const lowRaw = rawMaterials.filter((row) => row.stock > 0 && row.stock <= 10).length;
  const outRaw = rawMaterials.filter((row) => row.stock <= 0).length;

  function stockMeta(stock) {
    if (stock <= 0) return { label: "نافد", color: C.red };
    if (stock <= 10) return { label: "منخفض", color: C.brass };
    return { label: "متوفر", color: C.green };
  }

  return (
    <div>
      <SectionTitle eyebrow="المخزون الحالي" title="المخزون" icon={<Boxes size={14} />} />
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(190px, 1fr))", gap: 14, marginBottom: 18 }}>
        <Card><div style={{ color: C.muted, fontSize: 13 }}>قيمة مخزون الخامات</div><div style={{ color: C.brass, fontSize: 22, fontWeight: 800, marginTop: 8 }}>{fmt(rawValue)} ج.م</div></Card>
        <Card><div style={{ color: C.muted, fontSize: 13 }}>قيمة الإنتاج التام</div><div style={{ color: C.green, fontSize: 22, fontWeight: 800, marginTop: 8 }}>{fmt(finishedValue)} ج.م</div></Card>
        <Card><div style={{ color: C.muted, fontSize: 13 }}>خامات منخفضة</div><div style={{ color: C.brass, fontSize: 22, fontWeight: 800, marginTop: 8 }}>{lowRaw}</div></Card>
        <Card><div style={{ color: C.muted, fontSize: 13 }}>خامات نافدة</div><div style={{ color: C.red, fontSize: 22, fontWeight: 800, marginTop: 8 }}>{outRaw}</div></Card>
      </div>
      <SearchBox value={search} onChange={setSearch} placeholder="ابحث في المخزون..." />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 800, marginBottom: 12 }}>مخزون المواد الخام</div>
        {filteredMaterials.length === 0 ? <Empty text="لا توجد مواد خام مطابقة" /> : (
          <Table headers={["المادة", "الوحدة", "الرصيد", "سعر الوحدة", "القيمة", "الحالة"]}>
            {filteredMaterials.map((row) => { const meta = stockMeta(row.stock); return <tr key={row.id}><Td>{row.name}</Td><Td>{row.unit}</Td><Td style={{ color: meta.color, fontWeight: 700 }}>{fmt(row.stock)}</Td><Td>{fmt(row.unit_cost)} ج.م</Td><Td>{fmt(row.value)} ج.م</Td><Td style={{ color: meta.color, fontWeight: 700 }}>{meta.label}</Td></tr>; })}
          </Table>
        )}
      </Card>
      <Card>
        <div style={{ fontWeight: 800, marginBottom: 12 }}>مخزون المنتجات التامة</div>
        {filteredProducts.length === 0 ? <Empty text="لا توجد منتجات مطابقة" /> : (
          <Table headers={["المنتج", "الكود", "الرصيد", "متوسط التكلفة", "القيمة", "الحالة"]}>
            {filteredProducts.map((row) => { const meta = stockMeta(row.stock); return <tr key={row.id}><Td>{row.name}</Td><Td>{row.sku || "—"}</Td><Td style={{ color: meta.color, fontWeight: 700 }}>{fmt(row.stock)}</Td><Td>{fmt(row.unitCost)} ج.م</Td><Td>{fmt(row.value)} ج.م</Td><Td style={{ color: meta.color, fontWeight: 700 }}>{meta.label}</Td></tr>; })}
          </Table>
        )}
      </Card>
    </div>
  );
}

/* --------------------------------- Materials -------------------------------- */
function MaterialsTab({ data, canDelete, insertRow, deleteRow, updateRow }) {
  const blank = { name: "", unit: MATERIAL_UNITS[0], customUnit: "", unitCost: "", initialStock: "" };
  const [form, setForm] = useState(blank);
  const [editingId, setEditingId] = useState(null);
  const [pForm, setPForm] = useState({ materialId: "", qty: "", unitCost: "", supplierId: "", date: todayStr() });
  const [err, setErr] = useState("");
  const [search, setSearch] = useState("");

  function startEdit(m) {
    setEditingId(m.id);
    setForm({
      name: m.name,
      unit: MATERIAL_UNITS.includes(m.unit) ? m.unit : "أخرى",
      customUnit: MATERIAL_UNITS.includes(m.unit) ? "" : m.unit,
      unitCost: String(m.unit_cost),
      initialStock: String(m.initial_stock),
    });
  }
  function cancelEdit() { setEditingId(null); setForm(blank); setErr(""); }

  async function submitMaterial() {
    if (!form.name.trim()) return setErr("اكتب اسم المادة");
    const finalUnit = form.unit === "أخرى" ? (form.customUnit.trim() || "وحدة") : form.unit;
    const payload = { name: form.name.trim(), unit: finalUnit, unit_cost: num(form.unitCost), initial_stock: num(form.initialStock) };
    const e = editingId ? await updateRow("materials", editingId, payload) : await insertRow("materials", payload);
    if (e) return setErr(e);
    setForm(blank); setEditingId(null); setErr("");
  }
  async function addPurchase() {
    if (!pForm.materialId) return setErr("اختر المادة");
    if (num(pForm.qty) <= 0) return setErr("أدخل كمية أكبر من صفر");
    const e = await insertRow("materialPurchases", { material_id: pForm.materialId, supplier_id: pForm.supplierId || null, qty: num(pForm.qty), unit_cost: num(pForm.unitCost), purchase_date: pForm.date });
    if (e) return setErr(e);
    setPForm({ materialId: "", qty: "", unitCost: "", supplierId: "", date: todayStr() }); setErr("");
  }

  const filtered = data.materials.filter((m) => m.name.toLowerCase().includes(search.toLowerCase()));

  return (
    <div>
      <SectionTitle eyebrow="المخزون" title="المواد الخام" icon={<Package size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>{editingId ? "تعديل مادة خام" : "إضافة مادة خام جديدة"}</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="اسم المادة"><Input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="مثال: خشب زان" /></Field>
          <Field label="وحدة القياس">
            <Select value={form.unit} onChange={(e) => setForm({ ...form, unit: e.target.value })}>
              {MATERIAL_UNITS.map((u) => <option key={u} value={u}>{u}</option>)}
            </Select>
          </Field>
          {form.unit === "أخرى" && (
            <Field label="اكتب الوحدة"><Input value={form.customUnit} onChange={(e) => setForm({ ...form, customUnit: e.target.value })} /></Field>
          )}
          <Field label="سعر الوحدة (ج.م)"><Input type="number" value={form.unitCost} onChange={(e) => setForm({ ...form, unitCost: e.target.value })} /></Field>
          <Field label="الرصيد الافتتاحي"><Input type="number" value={form.initialStock} onChange={(e) => setForm({ ...form, initialStock: e.target.value })} /></Field>
        </div>
        <div style={{ marginTop: 12, display: "flex", gap: 8 }}>
          <Btn onClick={submitMaterial}>{editingId ? <><Pencil size={15} /> حفظ التعديل</> : <><Plus size={15} /> إضافة</>}</Btn>
          {editingId && <Btn variant="ghost" onClick={cancelEdit}><X size={15} /> إلغاء</Btn>}
        </div>
      </Card>

      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>تسجيل عملية شراء (تزيد المخزون وتُقيَّد على المورد)</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="المادة"><Select value={pForm.materialId} onChange={(e) => setPForm({ ...pForm, materialId: e.target.value })}><option value="">اختر المادة</option>{data.materials.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</Select></Field>
          <Field label="الكمية"><Input type="number" value={pForm.qty} onChange={(e) => setPForm({ ...pForm, qty: e.target.value })} /></Field>
          <Field label="سعر الوحدة عند الشراء"><Input type="number" value={pForm.unitCost} onChange={(e) => setPForm({ ...pForm, unitCost: e.target.value })} /></Field>
          <Field label="المورد"><Select value={pForm.supplierId} onChange={(e) => setPForm({ ...pForm, supplierId: e.target.value })}><option value="">بدون مورد محدد</option>{data.suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
          <Field label="التاريخ"><Input type="date" value={pForm.date} onChange={(e) => setPForm({ ...pForm, date: e.target.value })} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn onClick={addPurchase}><Plus size={15} /> تسجيل الشراء</Btn></div>
        {err && <Banner>{err}</Banner>}
      </Card>

      <Card>
        <SearchBox value={search} onChange={setSearch} placeholder="ابحث باسم المادة..." />
        {filtered.length === 0 ? <Empty text="لا توجد نتائج" /> : (
          <Table headers={["المادة", "الوحدة", "سعر الوحدة", "الرصيد الحالي", "قيمة المخزون", ""]}>
            {filtered.map((m) => {
              const stock = materialStock(m.id, data);
              return (
                <tr key={m.id}>
                  <Td>{m.name}</Td><Td>{m.unit}</Td><Td>{fmt(m.unit_cost)} ج.م</Td>
                  <Td style={{ color: stock < 0 ? C.red : C.text }}>{stock}</Td>
                  <Td>{fmt(stock * m.unit_cost)} ج.م</Td>
                  <Td style={{ display: "flex", gap: 10 }}>
                    <button onClick={() => startEdit(m)} style={{ background: "none", border: "none", cursor: "pointer", color: C.brass }}><Pencil size={15} /></button>
                    {canDelete && <button onClick={() => deleteRow("materials", m.id)} style={{ background: "none", border: "none", cursor: "pointer", color: C.red }}><Trash2 size={15} /></button>}
                  </Td>
                </tr>
              );
            })}
          </Table>
        )}
      </Card>
    </div>
  );
}

/* --------------------------------- Products --------------------------------- */
function ProductsTab({ data, canCreate, canEdit, canDelete, hideProfitInfo, insertRow, deleteRow, updateRow }) {
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

  const filtered = data.products.filter((p) => p.name.toLowerCase().includes(search.toLowerCase()));
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
                <tr key={i}><Td>{m?.name}</Td><Td>{r.qty} {m?.unit}</Td><Td>{fmt((m?.unit_cost || 0) * r.qty)} ج.م</Td>
                  <Td><button onClick={() => removeBomRow(i)} style={{ background: "none", border: "none", cursor: "pointer", color: C.red }}><Trash2 size={14} /></button></Td></tr>
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
                  <Td>{fmt(matCost)} ج.م</Td><Td>{fmt(p.labor_cost)} ج.م</Td><Td>{fmt(p.overhead_cost)} ج.م</Td>
                  <Td style={{ fontWeight: 700, color: C.brass }}>{fmt(unitCost)} ج.م</Td>
                  {!hideProfitInfo && (<>
                    <Td>{fmt(p.selling_price)} ج.م</Td>
                    <Td style={{ color: margin == null ? C.muted : margin >= 0 ? C.green : C.red }}>{margin == null ? "—" : `${margin.toFixed(1)}%`}</Td>
                  </>)}
                  <Td>{finishedStock(p.id, data)}</Td>
                  <Td style={{ display: "flex", gap: 10 }}>
                    {canEdit && <button onClick={() => startEdit(p)} style={{ background: "none", border: "none", cursor: "pointer", color: C.brass }}><Pencil size={15} /></button>}
                    {canDelete && <button onClick={() => deleteRow("products", p.id)} style={{ background: "none", border: "none", cursor: "pointer", color: C.red }}><Trash2 size={15} /></button>}
                  </Td>
                </tr>
              );
            })}
          </Table>
        )}
      </Card>
    </div>
  );
}

/* -------------------------------- Production -------------------------------- */
function ProductionTab({ data, insertRow, updateRow, deleteRow, canManage }) {
  const [form, setForm] = useState({ productId: "", qty: "", wastePercentage: "0", laborCost: "", overheadCost: "", date: todayStr() });
  const [err, setErr] = useState(""); const [ok, setOk] = useState("");
  const selectedProduct = data.products.find((p) => p.id === form.productId);

  async function submit() {
    setErr(""); setOk("");
    if (!form.productId) return setErr("اختر المنتج");
    const qty = num(form.qty);
    if (qty <= 0) return setErr("أدخل كمية أكبر من صفر");
    const product = data.products.find((p) => p.id === form.productId);
    const missing = [];
    for (const row of product.bom || []) {
      const need = row.qty * qty * (1 + num(form.wastePercentage) / 100);
      const have = materialStock(row.material_id, data);
      if (have < need) { const m = data.materials.find((x) => x.id === row.material_id); missing.push(`${m?.name}: متاح ${have} والمطلوب ${need}`); }
    }
    if (missing.length) return setErr("لا يوجد مخزون كافٍ من: " + missing.join(" · "));
    const wastePercentage = Math.max(0, num(form.wastePercentage));
    const materialsCost = bomUnitCost(product, data) * qty * (1 + wastePercentage / 100);
    const laborCost = num(form.laborCost) || product.labor_cost * qty;
    const overheadCost = num(form.overheadCost) || product.overhead_cost * qty;
    const totalCost = materialsCost + laborCost + overheadCost;
    const e = await insertRow("productionOrders", { product_id: form.productId, qty, waste_percentage: wastePercentage, materials_cost: materialsCost, labor_cost: laborCost, overhead_cost: overheadCost, total_cost: totalCost, unit_cost: totalCost / qty, order_date: form.date });
    if (e) return setErr(e);
    setOk("تم تسجيل أمر الإنتاج بنجاح، وتم خصم الخامات وإضافة الإنتاج التام");
    setForm({ productId: "", qty: "", wastePercentage: "0", laborCost: "", overheadCost: "", date: todayStr() });
  }

  async function quickEditProduction(o) {
    const qty = Number(window.prompt("الكمية الجديدة", o.qty));
    if (!Number.isFinite(qty) || qty <= 0) return;
    const waste = Number(window.prompt("نسبة الهالك الجديدة %", o.waste_percentage || 0));
    if (!Number.isFinite(waste) || waste < 0) return;
    const labor = Number(window.prompt("تكلفة العمالة", o.labor_cost || 0));
    const overhead = Number(window.prompt("التكاليف غير المباشرة", o.overhead_cost || 0));
    const product = data.products.find((p) => p.id === o.product_id);
    const oldWaste = num(o.waste_percentage);
    const missing = [];
    for (const row of product.bom || []) {
      const need = row.qty * qty * (1 + waste / 100);
      const oldConsumed = row.qty * o.qty * (1 + oldWaste / 100);
      const availableExcludingThisOrder = materialStock(row.material_id, data) + oldConsumed;
      if (availableExcludingThisOrder < need) {
        const m = data.materials.find((x) => x.id === row.material_id);
        missing.push(`${m?.name}: متاح ${availableExcludingThisOrder} والمطلوب ${need}`);
      }
    }
    if (missing.length) return window.alert("لا يوجد مخزون كافٍ من: " + missing.join(" · "));
    const materialsCost = bomUnitCost(product, data) * qty * (1 + waste / 100);
    const totalCost = materialsCost + labor + overhead;
    const e = await updateRow("productionOrders", o.id, { qty, waste_percentage: waste, materials_cost: materialsCost, labor_cost: labor, overhead_cost: overhead, total_cost: totalCost, unit_cost: totalCost / qty });
    if (e) setErr(e);
  }
  async function removeProduction(o) {
    if (!window.confirm("متأكد من حذف أمر الإنتاج؟")) return;
    const e = await deleteRow("productionOrders", o.id);
    if (e) setErr(e);
  }

  return (
    <div>
      <SectionTitle eyebrow="التصنيع" title="أوامر الإنتاج" icon={<Factory size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>أمر إنتاج جديد</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="المنتج"><Select value={form.productId} onChange={(e) => setForm({ ...form, productId: e.target.value })}><option value="">اختر المنتج</option>{data.products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</Select></Field>
          <Field label="الكمية المطلوب إنتاجها"><Input type="number" min="0" step="any" value={form.qty} onChange={(e) => setForm({ ...form, qty: e.target.value })} /></Field>
          <Field label="نسبة الهالك %"><Input type="number" min="0" step="0.1" value={form.wastePercentage} onChange={(e) => setForm({ ...form, wastePercentage: e.target.value })} /></Field>
          <Field label="تكلفة العمالة الإجمالية (اختياري)"><Input type="number" value={form.laborCost} onChange={(e) => setForm({ ...form, laborCost: e.target.value })} placeholder={selectedProduct ? `افتراضي: ${fmt(selectedProduct.labor_cost * (num(form.qty) || 1))}` : ""} /></Field>
          <Field label="تكاليف غير مباشرة إجمالية (اختياري)"><Input type="number" value={form.overheadCost} onChange={(e) => setForm({ ...form, overheadCost: e.target.value })} placeholder={selectedProduct ? `افتراضي: ${fmt(selectedProduct.overhead_cost * (num(form.qty) || 1))}` : ""} /></Field>
          <Field label="التاريخ"><Input type="date" value={form.date} onChange={(e) => setForm({ ...form, date: e.target.value })} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn onClick={submit}><Plus size={15} /> تسجيل أمر الإنتاج</Btn></div>
        {err && <Banner type="error">{err}</Banner>}
        {ok && <Banner type="success">{ok}</Banner>}
      </Card>
      <Card>
        {data.productionOrders.length === 0 ? <Empty text="لا توجد أوامر إنتاج مسجلة بعد" /> : (
          <Table headers={["التاريخ", "المنتج", "الكمية", "الهالك", "تكلفة الخامات", "عمالة", "غير مباشرة", "إجمالي التكلفة", "تكلفة الوحدة", ""]}>
            {[...data.productionOrders].reverse().map((o) => { const p = data.products.find((x) => x.id === o.product_id); return (
              <tr key={o.id}><Td>{o.order_date}</Td><Td>{p?.name || "—"}</Td><Td>{o.qty}</Td><Td>{num(o.waste_percentage).toFixed(1)}%</Td><Td>{fmt(o.materials_cost)}</Td><Td>{fmt(o.labor_cost)}</Td><Td>{fmt(o.overhead_cost)}</Td>
                <Td style={{ fontWeight: 700 }}>{fmt(o.total_cost)} ج.م</Td><Td style={{ color: C.brass }}>{fmt(o.unit_cost)} ج.م</Td>
                <Td>{canManage && <div style={{display:"flex",gap:8}}><button onClick={() => quickEditProduction(o)} style={{background:"none",border:"none",cursor:"pointer",color:C.brass}}><Pencil size={15}/></button><button onClick={() => removeProduction(o)} style={{background:"none",border:"none",cursor:"pointer",color:C.red}}><Trash2 size={15}/></button></div>}</Td></tr>
            ); })}
          </Table>
        )}
      </Card>
    </div>
  );
}

/* ----------------------------------- Sales ---------------------------------- */
function SalesTab({ data, insertRow, updateRow, deleteRow, canManage }) {
  const [form, setForm] = useState({ productId: "", customerId: "", qty: "", unitPrice: "", date: todayStr() });
  const [err, setErr] = useState(""); const [ok, setOk] = useState("");
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
    const total = unitPrice * qty;
    const e = await insertRow("sales", { product_id: form.productId, customer_id: form.customerId, qty, unit_price: unitPrice, total, sale_date: form.date });
    if (e) return setErr(e);
    setOk("تم تسجيل عملية البيع وتحديث مخزون المنتج التام وحساب العميل");
    setForm({ productId: "", customerId: "", qty: "", unitPrice: "", date: todayStr() });
  }

  async function quickEditSale(row) {
    const qty = Number(window.prompt("الكمية الجديدة", row.qty));
    if (!Number.isFinite(qty) || qty <= 0) return;
    const unitPrice = Number(window.prompt("سعر الوحدة الجديد", row.unit_price));
    if (!Number.isFinite(unitPrice) || unitPrice < 0) return;
    const availableExcludingThisSale = finishedStock(row.product_id, data) + row.qty;
    if (availableExcludingThisSale < qty) return window.alert(`المتاح ${availableExcludingThisSale} وحدة فقط`);
    const e = await updateRow("sales", row.id, { qty, unit_price: unitPrice, total: qty * unitPrice });
    if (e) setErr(e);
  }
  async function removeSale(row) {
    if (!window.confirm("متأكد من حذف عملية البيع؟")) return;
    const e = await deleteRow("sales", row.id);
    if (e) setErr(e);
  }

  return (
    <div>
      <SectionTitle eyebrow="التوزيع" title="المبيعات" icon={<ShoppingCart size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>عملية بيع جديدة</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="المنتج"><Select value={form.productId} onChange={(e) => setForm({ ...form, productId: e.target.value })}><option value="">اختر المنتج</option>{data.products.filter((p) => (p.item_type || "sale") !== "rental").map((p) => <option key={p.id} value={p.id}>{p.name} (متاح: {finishedStock(p.id, data)})</option>)}</Select></Field>
          <Field label="العميل"><Select value={form.customerId} onChange={(e) => setForm({ ...form, customerId: e.target.value })}><option value="">اختر العميل</option>{data.customers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
          <Field label="الكمية"><Input type="number" value={form.qty} onChange={(e) => setForm({ ...form, qty: e.target.value })} /></Field>
          <Field label="سعر الوحدة"><Input type="number" value={form.unitPrice} onChange={(e) => setForm({ ...form, unitPrice: e.target.value })} placeholder={selectedProduct ? `افتراضي: ${fmt(selectedProduct.selling_price)}` : ""} /></Field>
          <Field label="التاريخ"><Input type="date" value={form.date} onChange={(e) => setForm({ ...form, date: e.target.value })} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn onClick={submit}><Plus size={15} /> تسجيل البيع</Btn></div>
        {err && <Banner type="error">{err}</Banner>}
        {ok && <Banner type="success">{ok}</Banner>}
      </Card>
      <Card>
        {data.sales.length === 0 ? <Empty text="لا توجد مبيعات مسجلة بعد" /> : (
          <Table headers={["التاريخ", "المنتج", "العميل", "الكمية", "سعر الوحدة", "الإجمالي", ""]}>
            {[...data.sales].reverse().map((s) => { const p = data.products.find((x) => x.id === s.product_id); const c = data.customers.find((x) => x.id === s.customer_id); return (
              <tr key={s.id}><Td>{s.sale_date}</Td><Td>{p?.name || "—"}</Td><Td>{c?.name || "—"}</Td><Td>{s.qty}</Td><Td>{fmt(s.unit_price)} ج.م</Td><Td style={{ fontWeight: 700, color: C.green }}>{fmt(s.total)} ج.م</Td><Td>{canManage && <div style={{display:"flex",gap:8}}><button onClick={() => quickEditSale(s)} style={{background:"none",border:"none",cursor:"pointer",color:C.brass}}><Pencil size={15}/></button><button onClick={() => removeSale(s)} style={{background:"none",border:"none",cursor:"pointer",color:C.red}}><Trash2 size={15}/></button></div>}</Td></tr>
            ); })}
          </Table>
        )}
      </Card>
    </div>
  );
}

/* --------------------------------- Rentals ----------------------------------- */
function RentalsTab({ data, insertRow, updateRow, deleteRow, canManage }) {
  const [form, setForm] = useState({ productId: "", customerId: "", qty: "", rentalFee: "", startDate: todayStr(), expectedReturn: "" });
  const [err, setErr] = useState(""); const [ok, setOk] = useState("");

  async function submit() {
    setErr(""); setOk("");
    if (!form.productId) return setErr("اختر الصنف");
    if (!form.customerId) return setErr("اختر العميل");
    const qty = num(form.qty);
    if (qty <= 0) return setErr("أدخل كمية أكبر من صفر");
    const stock = finishedStock(form.productId, data);
    if (stock < qty) return setErr(`المتاح ${stock} وحدة فقط (بعد خصم اللي مؤجر حاليًا)`);
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
    await updateRow("rentals", r.id, { status: "returned", return_date: todayStr() });
  }

  const rentalProducts = data.products.filter((p) => (p.item_type || "sale") !== "sale");

  async function quickEditRental(r) {
    const qty = Number(window.prompt("الكمية الجديدة", r.qty));
    if (!Number.isFinite(qty) || qty <= 0) return;
    const rentalFee = Number(window.prompt("قيمة الإيجار الجديدة", r.rental_fee));
    if (!Number.isFinite(rentalFee) || rentalFee < 0) return;
    if (r.status === "active") {
      const availableExcludingThisRental = finishedStock(r.product_id, data) + r.qty;
      if (availableExcludingThisRental < qty) return window.alert(`المتاح ${availableExcludingThisRental} وحدة فقط`);
    }
    const e = await updateRow("rentals", r.id, { qty, rental_fee: rentalFee });
    if (e) setErr(e);
  }
  async function removeRental(r) {
    if (!window.confirm("متأكد من حذف عملية الإيجار؟")) return;
    const e = await deleteRow("rentals", r.id);
    if (e) setErr(e);
  }

  return (
    <div>
      <SectionTitle eyebrow="التأجير" title="الإيجارات" icon={<CalendarClock size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>عملية إيجار جديدة</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="الصنف"><Select value={form.productId} onChange={(e) => setForm({ ...form, productId: e.target.value })}><option value="">اختر الصنف</option>{rentalProducts.map((p) => <option key={p.id} value={p.id}>{p.name} (متاح: {finishedStock(p.id, data)})</option>)}</Select></Field>
          <Field label="العميل"><Select value={form.customerId} onChange={(e) => setForm({ ...form, customerId: e.target.value })}><option value="">اختر العميل</option>{data.customers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
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
        {data.rentals.length === 0 ? <Empty text="لا توجد عمليات إيجار مسجلة بعد" /> : (
          <Table headers={["الصنف", "العميل", "الكمية", "القيمة", "تاريخ البداية", "الاسترجاع المتوقع", "الحالة", ""]}>
            {[...data.rentals].reverse().map((r) => {
              const p = data.products.find((x) => x.id === r.product_id);
              const c = data.customers.find((x) => x.id === r.customer_id);
              return (
                <tr key={r.id}>
                  <Td>{p?.name || "—"}</Td><Td>{c?.name || "—"}</Td><Td>{r.qty}</Td>
                  <Td>{fmt(r.rental_fee)} ج.م</Td><Td>{r.start_date}</Td><Td>{r.expected_return_date || "—"}</Td>
                  <Td style={{ color: r.status === "active" ? C.brass : C.green, fontWeight: 700 }}>{r.status === "active" ? "مؤجر حاليًا" : "تم الاسترجاع"}</Td>
                  <Td><div style={{display:"flex",gap:8,alignItems:"center"}}>{r.status === "active" && <Btn variant="ghost" onClick={() => markReturned(r)} style={{ fontSize: 12, padding: "5px 10px" }}>تسجيل الاسترجاع</Btn>}{canManage && <><button onClick={() => quickEditRental(r)} style={{background:"none",border:"none",cursor:"pointer",color:C.brass}}><Pencil size={15}/></button><button onClick={() => removeRental(r)} style={{background:"none",border:"none",cursor:"pointer",color:C.red}}><Trash2 size={15}/></button></>}</div></Td>
                </tr>
              );
            })}
          </Table>
        )}
      </Card>
    </div>
  );
}

/* -------------------------------- Suppliers --------------------------------- */
function SuppliersTab({ data, insertRow, updateRow, deleteRow, canManage }) {
  const [name, setName] = useState(""); const [phone, setPhone] = useState("");
  const [editingId, setEditingId] = useState(null);
  const [payment, setPayment] = useState({ supplierId: "", amount: "", date: todayStr() });
  const [err, setErr] = useState(""); const [expanded, setExpanded] = useState(null);
  const [search, setSearch] = useState("");

  function startEdit(s) { setEditingId(s.id); setName(s.name); setPhone(s.phone || ""); }
  function cancelEdit() { setEditingId(null); setName(""); setPhone(""); setErr(""); }
  async function submitSupplier() {
    if (!name.trim()) return setErr("اكتب اسم المورد");
    const payload = { name: name.trim(), phone: phone.trim() };
    const e = editingId ? await updateRow("suppliers", editingId, payload) : await insertRow("suppliers", payload);
    if (e) return setErr(e);
    setName(""); setPhone(""); setEditingId(null); setErr("");
  }
  async function addPayment() {
    if (!payment.supplierId) return setErr("اختر المورد");
    if (num(payment.amount) <= 0) return setErr("أدخل مبلغ أكبر من صفر");
    const e = await insertRow("supplierPayments", { supplier_id: payment.supplierId, amount: num(payment.amount), payment_date: payment.date });
    if (e) return setErr(e);
    setPayment({ supplierId: "", amount: "", date: todayStr() }); setErr("");
  }
  const filtered = data.suppliers.filter((s) => s.name.toLowerCase().includes(search.toLowerCase()));

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
          <Field label="المورد"><Select value={payment.supplierId} onChange={(e) => setPayment({ ...payment, supplierId: e.target.value })}><option value="">اختر المورد</option>{data.suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
          <Field label="المبلغ"><Input type="number" value={payment.amount} onChange={(e) => setPayment({ ...payment, amount: e.target.value })} /></Field>
          <Field label="التاريخ"><Input type="date" value={payment.date} onChange={(e) => setPayment({ ...payment, date: e.target.value })} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn onClick={addPayment}><Wallet size={15} /> تسجيل الدفعة</Btn></div>
        {err && <Banner>{err}</Banner>}
      </Card>
      <Card>
        <SearchBox value={search} onChange={setSearch} placeholder="ابحث باسم المورد..." />
        {filtered.length === 0 ? <Empty text="لا توجد نتائج" /> : (
          <Table headers={["المورد", "الهاتف", "إجمالي المشتريات", "إجمالي المدفوع", "الرصيد المستحق", ""]}>
            {filtered.map((s) => { const bal = supplierBalance(s.id, data); return (
              <React.Fragment key={s.id}>
                <tr>
                  <Td>{s.name}</Td><Td>{s.phone || "—"}</Td><Td>{fmt(supplierPurchaseTotal(s.id, data))} ج.م</Td><Td>{fmt(supplierPaymentTotal(s.id, data))} ج.م</Td>
                  <Td style={{ fontWeight: 700, color: bal > 0 ? C.red : C.green }}>{fmt(bal)} ج.م</Td>
                  <Td style={{ display: "flex", gap: 10, alignItems: "center" }}>
                    <button onClick={() => startEdit(s)} style={{ background: "none", border: "none", cursor: "pointer", color: C.brass }}><Pencil size={15} /></button>
                    {canManage && <button onClick={async () => { if (window.confirm("متأكد من حذف المورد؟")) { const e = await deleteRow("suppliers", s.id); if (e) setErr(e); } }} style={{ background: "none", border: "none", cursor: "pointer", color: C.red }}><Trash2 size={15} /></button>}
                    <button onClick={() => setExpanded(expanded === s.id ? null : s.id)} style={{ background: "none", border: "none", color: C.brass, cursor: "pointer", fontSize: 12.5 }}>{expanded === s.id ? "إخفاء الحركات" : "عرض الحركات"}</button>
                  </Td>
                </tr>
                {expanded === s.id && <tr><Td colSpan={6} style={{ background: C.panelAlt }}><SupplierLedger supplierId={s.id} data={data} /></Td></tr>}
              </React.Fragment>
            ); })}
          </Table>
        )}
      </Card>
    </div>
  );
}
function SupplierLedger({ supplierId, data }) {
  const purchases = data.materialPurchases.filter((p) => p.supplier_id === supplierId).map((p) => ({ date: p.purchase_date, type: "شراء", amount: p.qty * p.unit_cost, note: data.materials.find((m) => m.id === p.material_id)?.name }));
  const payments = data.supplierPayments.filter((p) => p.supplier_id === supplierId).map((p) => ({ date: p.payment_date, type: "دفعة", amount: -p.amount, note: p.note }));
  const rows = [...purchases, ...payments].sort((a, b) => (a.date || "").localeCompare(b.date || ""));
  if (rows.length === 0) return <div style={{ color: C.muted, fontSize: 13 }}>لا توجد حركات مسجلة</div>;
  return <Table headers={["التاريخ", "النوع", "البيان", "المبلغ"]}>{rows.map((r, i) => <tr key={i}><Td>{r.date}</Td><Td style={{ color: r.type === "شراء" ? C.red : C.green }}>{r.type}</Td><Td>{r.note || "—"}</Td><Td>{fmt(Math.abs(r.amount))} ج.م</Td></tr>)}</Table>;
}

/* -------------------------------- Customers --------------------------------- */
function CustomersTab({ data, insertRow, updateRow, deleteRow, canManage }) {
  const [name, setName] = useState(""); const [phone, setPhone] = useState("");
  const [editingId, setEditingId] = useState(null);
  const [receipt, setReceipt] = useState({ customerId: "", amount: "", date: todayStr() });
  const [err, setErr] = useState(""); const [expanded, setExpanded] = useState(null);
  const [search, setSearch] = useState("");

  function startEdit(c) { setEditingId(c.id); setName(c.name); setPhone(c.phone || ""); }
  function cancelEdit() { setEditingId(null); setName(""); setPhone(""); setErr(""); }
  async function submitCustomer() {
    if (!name.trim()) return setErr("اكتب اسم العميل");
    const payload = { name: name.trim(), phone: phone.trim() };
    const e = editingId ? await updateRow("customers", editingId, payload) : await insertRow("customers", payload);
    if (e) return setErr(e);
    setName(""); setPhone(""); setEditingId(null); setErr("");
  }
  async function addReceipt() {
    if (!receipt.customerId) return setErr("اختر العميل");
    if (num(receipt.amount) <= 0) return setErr("أدخل مبلغ أكبر من صفر");
    const e = await insertRow("customerReceipts", { customer_id: receipt.customerId, amount: num(receipt.amount), receipt_date: receipt.date });
    if (e) return setErr(e);
    setReceipt({ customerId: "", amount: "", date: todayStr() }); setErr("");
  }
  const filtered = data.customers.filter((c) => c.name.toLowerCase().includes(search.toLowerCase()));

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
          <Field label="العميل"><Select value={receipt.customerId} onChange={(e) => setReceipt({ ...receipt, customerId: e.target.value })}><option value="">اختر العميل</option>{data.customers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
          <Field label="المبلغ"><Input type="number" value={receipt.amount} onChange={(e) => setReceipt({ ...receipt, amount: e.target.value })} /></Field>
          <Field label="التاريخ"><Input type="date" value={receipt.date} onChange={(e) => setReceipt({ ...receipt, date: e.target.value })} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn onClick={addReceipt}><Wallet size={15} /> تسجيل التحصيل</Btn></div>
        {err && <Banner>{err}</Banner>}
      </Card>
      <Card>
        <SearchBox value={search} onChange={setSearch} placeholder="ابحث باسم العميل..." />
        {filtered.length === 0 ? <Empty text="لا توجد نتائج" /> : (
          <Table headers={["العميل", "الهاتف", "إجمالي المبيعات والإيجارات", "إجمالي التحصيل", "الرصيد المستحق", ""]}>
            {filtered.map((c) => { const bal = customerBalance(c.id, data); return (
              <React.Fragment key={c.id}>
                <tr>
                  <Td>{c.name}</Td><Td>{c.phone || "—"}</Td><Td>{fmt(customerSaleTotal(c.id, data) + customerRentalTotal(c.id, data))} ج.م</Td><Td>{fmt(customerReceiptTotal(c.id, data))} ج.م</Td>
                  <Td style={{ fontWeight: 700, color: bal > 0 ? C.brass : C.green }}>{fmt(bal)} ج.م</Td>
                  <Td style={{ display: "flex", gap: 10, alignItems: "center" }}>
                    <button onClick={() => startEdit(c)} style={{ background: "none", border: "none", cursor: "pointer", color: C.brass }}><Pencil size={15} /></button>
                    {canManage && <button onClick={async () => { if (window.confirm("متأكد من حذف العميل؟")) { const e = await deleteRow("customers", c.id); if (e) setErr(e); } }} style={{ background: "none", border: "none", cursor: "pointer", color: C.red }}><Trash2 size={15} /></button>}
                    <button onClick={() => setExpanded(expanded === c.id ? null : c.id)} style={{ background: "none", border: "none", color: C.brass, cursor: "pointer", fontSize: 12.5 }}>{expanded === c.id ? "إخفاء الحركات" : "عرض الحركات"}</button>
                  </Td>
                </tr>
                {expanded === c.id && <tr><Td colSpan={6} style={{ background: C.panelAlt }}><CustomerLedger customerId={c.id} data={data} /></Td></tr>}
              </React.Fragment>
            ); })}
          </Table>
        )}
      </Card>
    </div>
  );
}
function CustomerLedger({ customerId, data }) {
  const sales = data.sales.filter((s) => s.customer_id === customerId).map((s) => ({ date: s.sale_date, type: "بيع", amount: s.total, note: data.products.find((p) => p.id === s.product_id)?.name }));
  const rentals = data.rentals.filter((r) => r.customer_id === customerId).map((r) => ({ date: r.start_date, type: "إيجار", amount: r.rental_fee, note: data.products.find((p) => p.id === r.product_id)?.name }));
  const receipts = data.customerReceipts.filter((r) => r.customer_id === customerId).map((r) => ({ date: r.receipt_date, type: "تحصيل", amount: -r.amount, note: r.note }));
  const rows = [...sales, ...rentals, ...receipts].sort((a, b) => (a.date || "").localeCompare(b.date || ""));
  if (rows.length === 0) return <div style={{ color: C.muted, fontSize: 13 }}>لا توجد حركات مسجلة</div>;
  return <Table headers={["التاريخ", "النوع", "البيان", "المبلغ"]}>{rows.map((r, i) => <tr key={i}><Td>{r.date}</Td><Td style={{ color: r.type === "تحصيل" ? C.green : C.brass }}>{r.type}</Td><Td>{r.note || "—"}</Td><Td>{fmt(Math.abs(r.amount))} ج.م</Td></tr>)}</Table>;
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
      <Card><div style={{ color: C.muted, fontSize: 13 }}>إجمالي قيمة المشتريات</div><div style={{ color: C.brass, fontSize: 23, fontWeight: 800, marginTop: 8 }}>{fmt(total)} ج.م</div></Card>
      <Card><div style={{ color: C.muted, fontSize: 13 }}>عدد عمليات الشراء</div><div style={{ color: C.green, fontSize: 23, fontWeight: 800, marginTop: 8 }}>{data.materialPurchases.length}</div></Card>
    </div>
    <Card style={{ marginBottom: 18 }}>
      <div style={{ fontWeight: 800, marginBottom: 12 }}>عملية شراء جديدة</div>
      <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
        <Field label="المادة"><Select value={form.materialId} onChange={(e) => setForm({ ...form, materialId: e.target.value })}><option value="">اختر المادة</option>{data.materials.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</Select></Field>
        <Field label="المورد"><Select value={form.supplierId} onChange={(e) => setForm({ ...form, supplierId: e.target.value })}><option value="">بدون مورد محدد</option>{data.suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
        <Field label="الكمية"><Input type="number" min="0" step="any" value={form.qty} onChange={(e) => setForm({ ...form, qty: e.target.value })} /></Field>
        <Field label="سعر الوحدة"><Input type="number" min="0" step="any" value={form.unitCost} onChange={(e) => setForm({ ...form, unitCost: e.target.value })} /></Field>
        <Field label="التاريخ"><Input type="date" value={form.date} onChange={(e) => setForm({ ...form, date: e.target.value })} /></Field>
      </div>
      <div style={{ marginTop: 12 }}><Btn onClick={submit}><Plus size={15}/> تسجيل الشراء</Btn></div>
      {err && <Banner type="error">{err}</Banner>}{ok && <Banner type="success">{ok}</Banner>}
    </Card>
    <Card>{data.materialPurchases.length === 0 ? <Empty text="لا توجد مشتريات مسجلة" /> : <Table headers={["التاريخ","المادة","المورد","الكمية","سعر الوحدة","الإجمالي",""]}>{[...data.materialPurchases].reverse().map((p) => {
      const m = data.materials.find((x) => x.id === p.material_id); const sup = data.suppliers.find((x) => x.id === p.supplier_id);
      return <tr key={p.id}><Td>{p.purchase_date}</Td><Td>{m?.name || "—"}</Td><Td>{sup?.name || "—"}</Td><Td>{p.qty} {m?.unit || ""}</Td><Td>{fmt(p.unit_cost)} ج.م</Td><Td style={{fontWeight:700}}>{fmt(num(p.qty)*num(p.unit_cost))} ج.م</Td><Td>{canDelete && <button onClick={() => remove(p)} style={{background:"none",border:"none",cursor:"pointer",color:C.red}}><Trash2 size={15}/></button>}</Td></tr>
    })}</Table>}</Card>
  </div>;
}

/* -------------------------------- Expenses --------------------------------- */
function ExpensesTab({ data, insertRow, deleteRow, canDelete }) {
  const categories = ["كهرباء", "إيجار", "رواتب", "نقل", "صيانة", "إنترنت", "تسويق", "أخرى"];
  const [form, setForm] = useState({ category: categories[0], amount: "", date: todayStr(), notes: "" });
  const [err, setErr] = useState(""); const [ok, setOk] = useState("");
  async function submit() {
    setErr(""); setOk("");
    if (num(form.amount) <= 0) return setErr("أدخل مبلغ أكبر من صفر");
    const { data: authData } = await supabase.auth.getUser();
    const e = await insertRow("expenses", { category: form.category, amount: num(form.amount), expense_date: form.date, notes: form.notes.trim() || null, created_by: authData?.user?.id || null });
    if (e) return setErr(e);
    setOk("تم تسجيل المصروف بنجاح");
    setForm({ category: categories[0], amount: "", date: todayStr(), notes: "" });
  }
  async function remove(row) {
    if (!window.confirm("متأكد من حذف المصروف؟")) return;
    const e = await deleteRow("expenses", row.id); if (e) setErr(e);
  }
  const total = data.expenses.reduce((sum, e) => sum + num(e.amount), 0);
  return <div>
    <SectionTitle eyebrow="المالية" title="المصروفات" icon={<ReceiptText size={14} />} />
    <Card style={{ marginBottom: 18 }}><div style={{ color: C.muted, fontSize: 13 }}>إجمالي المصروفات المسجلة</div><div style={{ color: C.red, fontSize: 24, fontWeight: 800, marginTop: 8 }}>{fmt(total)} ج.م</div></Card>
    <Card style={{ marginBottom: 18 }}>
      <div style={{ fontWeight: 800, marginBottom: 12 }}>مصروف جديد</div>
      <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
        <Field label="البند"><Select value={form.category} onChange={(e) => setForm({ ...form, category: e.target.value })}>{categories.map((c) => <option key={c} value={c}>{c}</option>)}</Select></Field>
        <Field label="المبلغ"><Input type="number" min="0" step="any" value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} /></Field>
        <Field label="التاريخ"><Input type="date" value={form.date} onChange={(e) => setForm({ ...form, date: e.target.value })} /></Field>
        <Field label="ملاحظات"><Input value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} /></Field>
      </div>
      <div style={{ marginTop: 12 }}><Btn onClick={submit}><Plus size={15}/> تسجيل المصروف</Btn></div>
      {err && <Banner type="error">{err}</Banner>}{ok && <Banner type="success">{ok}</Banner>}
    </Card>
    <Card>{data.expenses.length === 0 ? <Empty text="لا توجد مصروفات مسجلة" /> : <Table headers={["التاريخ","البند","الملاحظات","المبلغ",""]}>{[...data.expenses].reverse().map((e) => <tr key={e.id}><Td>{e.expense_date}</Td><Td>{e.category}</Td><Td>{e.notes || "—"}</Td><Td style={{fontWeight:700,color:C.red}}>{fmt(e.amount)} ج.م</Td><Td>{canDelete && <button onClick={() => remove(e)} style={{background:"none",border:"none",cursor:"pointer",color:C.red}}><Trash2 size={15}/></button>}</Td></tr>)}</Table>}</Card>
  </div>;
}

/* ---------------------------------- Reports --------------------------------- */
function ReportsTab({ data }) {
  const rows = data.products.map((p) => {
    const revenue = data.sales.filter((s) => s.product_id === p.id).reduce((s, o) => s + o.total, 0);
    const qtySold = soldQty(p.id, data);
    const unitCost = avgProductionUnitCost(p.id, data);
    const cogs = qtySold * unitCost;
    const profit = revenue - cogs;
    const margin = revenue > 0 ? (profit / revenue) * 100 : null;
    return { name: p.name, revenue, cogs, profit, margin, qtySold };
  });
  const baseTotals = rows.reduce((a, r) => ({ revenue: a.revenue + r.revenue, cogs: a.cogs + r.cogs, profit: a.profit + r.profit }), { revenue: 0, cogs: 0, profit: 0 });
  const expensesTotal = data.expenses.reduce((sum, e) => sum + num(e.amount), 0);
  const totals = { ...baseTotals, expenses: expensesTotal, profit: baseTotals.profit - expensesTotal };
  const chartData = rows.map((r) => ({ name: r.name.length > 10 ? r.name.slice(0, 10) + "…" : r.name, الربح: Math.round(r.profit) }));

  return (
    <div>
      <SectionTitle eyebrow="الأداء" title="تقارير الربحية" icon={<BarChart3 size={14} />} />
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: 14, marginBottom: 18 }}>
        <Card><div style={{ fontSize: 12.5, color: C.muted, marginBottom: 6 }}>إجمالي الإيرادات</div><div style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 20, color: C.brass }}>{fmt(totals.revenue)} ج.م</div></Card>
        <Card><div style={{ fontSize: 12.5, color: C.muted, marginBottom: 6 }}>إجمالي تكلفة المبيعات</div><div style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 20, color: C.wood }}>{fmt(totals.cogs)} ج.م</div></Card>
        <Card><div style={{ fontSize: 12.5, color: C.muted, marginBottom: 6 }}>إجمالي المصروفات</div><div style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 20, color: C.red }}>{fmt(totals.expenses)} ج.م</div></Card>
        <Card><div style={{ fontSize: 12.5, color: C.muted, marginBottom: 6 }}>صافي الربح بعد المصروفات</div><div style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 20, color: totals.profit >= 0 ? C.green : C.red }}>{fmt(totals.profit)} ج.م</div></Card>
      </div>
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontSize: 13.5, color: C.muted, marginBottom: 12, fontWeight: 700 }}>الربح لكل منتج</div>
        {chartData.length === 0 ? <Empty text="لا توجد بيانات كافية بعد" /> : (
          <ResponsiveContainer width="100%" height={260}>
            <BarChart data={chartData}>
              <CartesianGrid stroke={C.border} strokeDasharray="3 3" />
              <XAxis dataKey="name" stroke={C.muted} fontSize={12} />
              <YAxis stroke={C.muted} fontSize={12} />
              <Tooltip contentStyle={{ background: C.panelAlt, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text }} />
              <Bar dataKey="الربح" radius={[4, 4, 0, 0]} fill={C.green} />
            </BarChart>
          </ResponsiveContainer>
        )}
      </Card>
      <Card>
        {rows.length === 0 ? <Empty text="أضف منتجات ومبيعات لعرض التقرير" /> : (
          <Table headers={["المنتج", "الكمية المباعة", "الإيراد", "تكلفة المبيعات", "الربح", "هامش الربح"]}>
            {rows.map((r, i) => (
              <tr key={i}><Td>{r.name}</Td><Td>{r.qtySold}</Td><Td>{fmt(r.revenue)} ج.م</Td><Td>{fmt(r.cogs)} ج.م</Td>
                <Td style={{ fontWeight: 700, color: r.profit >= 0 ? C.green : C.red }}>{fmt(r.profit)} ج.م</Td>
                <Td>{r.margin == null ? "—" : `${r.margin.toFixed(1)}%`}</Td></tr>
            ))}
          </Table>
        )}
      </Card>
    </div>
  );
}

/* ----------------------------------- Team ------------------------------------ */
function TeamTab() {
  const [profiles, setProfiles] = useState(null);
  const [pending, setPending] = useState({});
  const [msg, setMsg] = useState("");

  const load = useCallback(async () => {
    const fetchResult = await supabase.from("profiles").select("*").order("created_at", { ascending: true });
    const { data, error } = fetchResult;
    console.info("[permissions] refetchResult", fetchResult);
    setProfiles(error ? [] : data);
    if (!error) {
      const initial = {};
      for (const p of data || []) initial[p.id] = { role: p.role, ...permissionsForProfile(p) };
      setPending(initial);
      console.info("[permissions] currentState", initial);
    }
    return fetchResult;
  }, []);
  useEffect(() => { load(); }, [load]);

  function patchUser(userId, patch) {
    setPending((prev) => ({ ...prev, [userId]: { ...(prev[userId] || {}), ...patch } }));
  }
  function togglePage(userId, pageId) {
    const current = pending[userId] || {};
    const pages = current.pages || [];
    patchUser(userId, { pages: pages.includes(pageId) ? pages.filter((x) => x !== pageId) : [...pages, pageId] });
  }
  async function savePermissions(userId) {
    const current = pending[userId];
    if (!current) return;
    setMsg("");
    const role = current.role;
    const permissions = role === "manager" ? null : {
      pages: (current.pages || []).filter((p) => p !== "team"),
      can_delete: Boolean(current.can_delete),
      view_financials: Boolean(current.view_financials),
      can_create_products: Boolean(current.can_create_products),
      can_edit_products: Boolean(current.can_edit_products),
      ...Object.fromEntries(ACTION_PERMISSIONS.map((key) => [key, Boolean(current[key])])),
    };
    const mutationResult = await supabase.from("profiles").update({ role, permissions }).eq("id", userId);
    const result = await syncMutation({ scope:"permissions:update", mutationResult, refetch:load });
    if (result.error) return setMsg(result.error.message);
    setMsg("تم حفظ الصلاحيات بنجاح");
  }

  if (profiles === null) return <Empty text="جارِ التحميل..." />;
  return (
    <div>
      <SectionTitle eyebrow="التحكم بالصلاحيات" title="الفريق والصلاحيات" icon={<ShieldCheck size={14} />} />
      {msg && <Banner type={msg.includes("بنجاح") ? "success" : "error"}>{msg}</Banner>}
      <div style={{ display: "grid", gap: 14, marginTop: 14 }}>
        {profiles.map((p) => {
          const current = pending[p.id] || { role: p.role, ...permissionsForProfile(p) };
          const isManager = current.role === "manager";
          return <Card key={p.id}>
            <div style={{ display: "flex", justifyContent: "space-between", gap: 12, flexWrap: "wrap", alignItems: "center" }}>
              <div><div style={{ fontWeight: 800 }}>{p.full_name || "بدون اسم"}</div><div style={{ color: C.muted, fontSize: 12 }}>{p.id.slice(0, 8)}…</div></div>
              <Field label="الصفة" style={{ maxWidth: 220 }}>
                <Select value={current.role} onChange={(e) => patchUser(p.id, { role: e.target.value, ...permissionsForProfile({ role: e.target.value }) })}>
                  {Object.entries(ROLES).map(([k, r]) => <option key={k} value={k}>{r.label}</option>)}
                </Select>
              </Field>
            </div>
            {!isManager && <>
              <div style={{ color: C.muted, fontSize: 13, margin: "16px 0 8px" }}>الصفحات المسموح بها</div>
              <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(170px, 1fr))", gap: 8 }}>
                {ALL_PAGE_IDS.filter((id) => id !== "team").map((id) => <label key={id} style={{ display: "flex", alignItems: "center", gap: 8, background: C.bg, border: `1px solid ${C.border}`, borderRadius: 8, padding: "8px 10px" }}>
                  <input type="checkbox" checked={(current.pages || []).includes(id)} onChange={() => togglePage(p.id, id)} />{PAGE_LABELS[id]}
                </label>)}
              </div>
              <div style={{ display: "flex", gap: 18, flexWrap: "wrap", marginTop: 14 }}>
                <label style={{ display: "flex", alignItems: "center", gap: 8 }}><input type="checkbox" checked={Boolean(current.can_delete)} onChange={(e) => patchUser(p.id, { can_delete: e.target.checked })} />السماح بالحذف</label>
                <label style={{ display: "flex", alignItems: "center", gap: 8 }}><input type="checkbox" checked={Boolean(current.view_financials)} onChange={(e) => patchUser(p.id, { view_financials: e.target.checked })} />عرض الأرباح والتقارير المالية</label>
                <label style={{ display: "flex", alignItems: "center", gap: 8 }}><input type="checkbox" checked={Boolean(current.can_create_products)} onChange={(e) => patchUser(p.id, { can_create_products: e.target.checked })} />إضافة منتجات جديدة</label>
                <label style={{ display: "flex", alignItems: "center", gap: 8 }}><input type="checkbox" checked={Boolean(current.can_edit_products)} onChange={(e) => patchUser(p.id, { can_edit_products: e.target.checked })} />تعديل المنتجات الموجودة</label>
              </div>
              <div style={{ color: C.muted, fontSize: 13, margin: "18px 0 8px" }}>صلاحيات V2.2 التفصيلية</div>
              <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(210px, 1fr))", gap: 8 }}>
                {ACTION_PERMISSIONS.map((key) => <label key={key} style={{ display: "flex", alignItems: "center", gap: 8, background: C.bg, border: `1px solid ${C.border}`, borderRadius: 8, padding: "8px 10px" }}>
                  <input type="checkbox" checked={Boolean(current[key])} onChange={(e) => patchUser(p.id, { [key]: e.target.checked })} />{PERMISSION_LABELS[key]}
                </label>)}
              </div>
            </>}
            <div style={{ marginTop: 16 }}><Btn onClick={() => savePermissions(p.id)}>حفظ الصلاحيات</Btn></div>
          </Card>;
        })}
      </div>
    </div>
  );
}
