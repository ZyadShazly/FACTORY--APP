import React, { useState, useEffect, useMemo, useCallback } from "react";
import { supabase } from "./supabaseClient";
import {
  LayoutDashboard, Package, Layers, Factory, ShoppingCart, Truck, Users,
  BarChart3, Plus, Trash2, AlertCircle, CheckCircle2, Wallet, Boxes, LogOut,
} from "lucide-react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Legend,
} from "recharts";

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
  accountant: { label: "المحاسب", desc: "إضافة العمليات بدون حذف، وبدون رؤية الأرباح والهوامش" },
  production: { label: "موظف الإنتاج", desc: "تسجيل أوامر الإنتاج فقط" },
};
const NAV_BY_ROLE = {
  manager: ["dashboard", "materials", "products", "production", "sales", "suppliers", "customers", "reports"],
  accountant: ["materials", "products", "production", "sales", "suppliers", "customers"],
  production: ["production"],
};

const TABLES = {
  materials: "materials",
  materialPurchases: "material_purchases",
  products: "products",
  productionOrders: "production_orders",
  sales: "sales",
  suppliers: "suppliers",
  supplierPayments: "supplier_payments",
  customers: "customers",
  customerReceipts: "customer_receipts",
};
const EMPTY_DATA = {
  materials: [], materialPurchases: [], products: [], productionOrders: [],
  sales: [], suppliers: [], supplierPayments: [], customers: [], customerReceipts: [],
};

/* ------------------------------ دوال الحسابات ------------------------------ */
function materialConsumedQty(materialId, data) {
  let total = 0;
  for (const o of data.productionOrders) {
    const p = data.products.find((x) => x.id === o.product_id);
    if (!p) continue;
    const row = (p.bom || []).find((r) => r.material_id === materialId);
    if (row) total += row.qty * o.qty;
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
function finishedStock(productId, data) { return producedQty(productId, data) - soldQty(productId, data); }
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
function customerBalance(customerId, data) { return customerSaleTotal(customerId, data) - customerReceiptTotal(customerId, data); }

/* ------------------------------- عناصر عامة ------------------------------- */
function Card({ children, style, ...rest }) {
  return <div style={{ background: C.panel, border: `1px solid ${C.border}`, borderRadius: 12, padding: 18, ...style }} {...rest}>{children}</div>;
}
function Field({ label, children }) {
  return <label style={{ display: "flex", flexDirection: "column", gap: 6, fontSize: 13, color: C.muted, flex: 1, minWidth: 140 }}>{label}{children}</label>;
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

/* ----------------------------- شاشة الدخول والتسجيل ----------------------------- */
function AuthGate() {
  const [mode, setMode] = useState("login"); // login | signup
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [role, setRole] = useState("accountant");
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
          const { error: profErr } = await supabase.from("profiles").insert({ id: userId, full_name: fullName.trim(), role });
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
      <div style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 20, color: C.brass, display: "flex", alignItems: "center", gap: 8, marginBottom: 22 }}>
        <Boxes size={22} /> إدارة المصنع
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
                {Object.entries(ROLES).map(([k, r]) => <option key={k} value={k}>{r.label}</option>)}
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
  const [session, setSession] = useState(undefined);
  const [profile, setProfile] = useState(undefined);
  const [data, setData] = useState(null);
  const [tab, setTab] = useState(null);

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => setSession(session));
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => setSession(session));
    return () => sub.subscription.unsubscribe();
  }, []);

  const fetchProfile = useCallback(async (userId) => {
    const { data: rows } = await supabase.from("profiles").select("*").eq("id", userId).limit(1);
    setProfile(rows && rows.length ? rows[0] : null);
  }, []);

  useEffect(() => {
    if (session === undefined) return;
    if (!session) { setProfile(null); return; }
    fetchProfile(session.user.id);
  }, [session, fetchProfile]);

  const refetchTable = useCallback(async (key) => {
    const table = TABLES[key];
    const { data: rows } = await supabase.from(table).select("*").order("created_at", { ascending: true });
    setData((prev) => ({ ...(prev || EMPTY_DATA), [key]: rows || [] }));
  }, []);

  useEffect(() => {
    if (!session) return;
    (async () => {
      const entries = await Promise.all(
        Object.entries(TABLES).map(async ([key, table]) => {
          const { data: rows } = await supabase.from(table).select("*").order("created_at", { ascending: true });
          return [key, rows || []];
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
  const activeTab = tab || NAV_BY_ROLE[role][0];
  const ALL_NAV = [
    { id: "dashboard", label: "لوحة التحكم", icon: LayoutDashboard },
    { id: "materials", label: "المواد الخام", icon: Package },
    { id: "products", label: "المنتجات والتكلفة", icon: Layers },
    { id: "production", label: "أوامر الإنتاج", icon: Factory },
    { id: "sales", label: "المبيعات", icon: ShoppingCart },
    { id: "suppliers", label: "الموردين", icon: Truck },
    { id: "customers", label: "العملاء", icon: Users },
    { id: "reports", label: "التقارير", icon: BarChart3 },
  ];
  const NAV = ALL_NAV.filter((n) => NAV_BY_ROLE[role].includes(n.id));

  /* ------------------------------- دوال الإضافة والحذف ------------------------------- */
  async function insertRow(key, payload) {
    const { error } = await supabase.from(TABLES[key]).insert(payload);
    if (!error) await refetchTable(key);
    return error?.message || null;
  }
  async function deleteRow(key, id) {
    const { error } = await supabase.from(TABLES[key]).delete().eq("id", id);
    if (!error) await refetchTable(key);
    return error?.message || null;
  }
  async function updateRow(key, id, patch) {
    const { error } = await supabase.from(TABLES[key]).update(patch).eq("id", id);
    if (!error) await refetchTable(key);
    return error?.message || null;
  }

  return (
    <div dir="rtl" style={{ fontFamily: "Tajawal, sans-serif", background: C.bg, minHeight: "100vh", display: "flex", color: C.text }}>
      <div style={{ width: 210, flexShrink: 0, background: "#191612", borderLeft: `1px solid ${C.border}`, padding: "20px 12px", display: "flex", flexDirection: "column", gap: 4, position: "sticky", top: 0, height: "100vh", overflowY: "auto" }}>
        <div style={{ padding: "0 8px 18px 8px" }}>
          <div style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 17, color: C.brass, display: "flex", alignItems: "center", gap: 8 }}>
            <Boxes size={20} /> إدارة المصنع
          </div>
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
        {activeTab === "materials" && <MaterialsTab data={data} canDelete={role === "manager"} insertRow={insertRow} deleteRow={deleteRow} updateRow={updateRow} />}
        {activeTab === "products" && <ProductsTab data={data} canDelete={role === "manager"} hideProfitInfo={role !== "manager"} insertRow={insertRow} deleteRow={deleteRow} />}
        {activeTab === "production" && <ProductionTab data={data} insertRow={insertRow} />}
        {activeTab === "sales" && <SalesTab data={data} insertRow={insertRow} />}
        {activeTab === "suppliers" && <SuppliersTab data={data} insertRow={insertRow} />}
        {activeTab === "customers" && <CustomersTab data={data} insertRow={insertRow} />}
        {activeTab === "reports" && <ReportsTab data={data} />}
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
    const finishedValue = data.products.reduce((s, p) => s + finishedStock(p.id, data) * avgProductionUnitCost(p.id, data), 0);
    const totalSuppliers = data.suppliers.reduce((s, sup) => s + supplierBalance(sup.id, data), 0);
    const totalCustomers = data.customers.reduce((s, c) => s + customerBalance(c.id, data), 0);
    const monthKey = todayStr().slice(0, 7);
    const ordersThisMonth = data.productionOrders.filter((o) => (o.order_date || "").slice(0, 7) === monthKey).length;
    let revenue = 0, cogs = 0;
    for (const s of data.sales) {
      revenue += s.total;
      const p = data.products.find((x) => x.id === s.product_id);
      cogs += p ? s.qty * avgProductionUnitCost(p.id, data) : 0;
    }
    return { materialsValue, finishedValue, totalSuppliers, totalCustomers, ordersThisMonth, profit: revenue - cogs };
  }, [data]);

  const chartData = data.products.slice(0, 8).map((p) => {
    const revenue = data.sales.filter((s) => s.product_id === p.id).reduce((s, o) => s + o.total, 0);
    const cost = data.sales.filter((s) => s.product_id === p.id).reduce((s, o) => s + o.qty * avgProductionUnitCost(p.id, data), 0);
    return { name: p.name.length > 10 ? p.name.slice(0, 10) + "…" : p.name, الإيراد: Math.round(revenue), التكلفة: Math.round(cost) };
  });

  const cards = [
    { label: "قيمة مخزون الخامات", value: `${fmt(stats.materialsValue)} ر.س`, color: C.brass },
    { label: "قيمة مخزون الإنتاج التام", value: `${fmt(stats.finishedValue)} ر.س`, color: C.wood },
    { label: "مستحق للموردين", value: `${fmt(stats.totalSuppliers)} ر.س`, color: C.red },
    { label: "مستحق من العملاء", value: `${fmt(stats.totalCustomers)} ر.س`, color: C.green },
    { label: "أوامر إنتاج هذا الشهر", value: stats.ordersThisMonth, color: C.brass },
    { label: "صافي الربح التقديري", value: `${fmt(stats.profit)} ر.س`, color: stats.profit >= 0 ? C.green : C.red },
  ];

  return (
    <div>
      <SectionTitle eyebrow="نظرة عامة" title="لوحة التحكم" icon={<LayoutDashboard size={14} />} />
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: 14, marginBottom: 22 }}>
        {cards.map((c, i) => (
          <Card key={i}>
            <div style={{ fontSize: 12.5, color: C.muted, marginBottom: 8 }}>{c.label}</div>
            <div style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 22, color: c.color }}>{c.value}</div>
          </Card>
        ))}
      </div>
      <Card>
        <div style={{ fontSize: 13.5, color: C.muted, marginBottom: 12, fontWeight: 700 }}>الإيراد مقابل التكلفة لكل منتج</div>
        {chartData.length === 0 ? <Empty text="لا توجد بيانات مبيعات بعد لعرض الرسم البياني" /> : (
          <ResponsiveContainer width="100%" height={280}>
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

/* --------------------------------- Materials -------------------------------- */
function MaterialsTab({ data, canDelete, insertRow, deleteRow }) {
  const [form, setForm] = useState({ name: "", unit: "", unitCost: "", initialStock: "" });
  const [pForm, setPForm] = useState({ materialId: "", qty: "", unitCost: "", supplierId: "", date: todayStr() });
  const [err, setErr] = useState("");

  async function addMaterial() {
    if (!form.name.trim()) return setErr("اكتب اسم المادة");
    const e = await insertRow("materials", { name: form.name.trim(), unit: form.unit.trim() || "وحدة", unit_cost: num(form.unitCost), initial_stock: num(form.initialStock) });
    if (e) return setErr(e);
    setForm({ name: "", unit: "", unitCost: "", initialStock: "" }); setErr("");
  }
  async function addPurchase() {
    if (!pForm.materialId) return setErr("اختر المادة");
    if (num(pForm.qty) <= 0) return setErr("أدخل كمية أكبر من صفر");
    const e = await insertRow("materialPurchases", { material_id: pForm.materialId, supplier_id: pForm.supplierId || null, qty: num(pForm.qty), unit_cost: num(pForm.unitCost), purchase_date: pForm.date });
    if (e) return setErr(e);
    setPForm({ materialId: "", qty: "", unitCost: "", supplierId: "", date: todayStr() }); setErr("");
  }

  return (
    <div>
      <SectionTitle eyebrow="المخزون" title="المواد الخام" icon={<Package size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>إضافة مادة خام جديدة</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="اسم المادة"><Input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="مثال: خشب زان" /></Field>
          <Field label="وحدة القياس"><Input value={form.unit} onChange={(e) => setForm({ ...form, unit: e.target.value })} placeholder="متر / كجم / قطعة" /></Field>
          <Field label="سعر الوحدة (ر.س)"><Input type="number" value={form.unitCost} onChange={(e) => setForm({ ...form, unitCost: e.target.value })} /></Field>
          <Field label="الرصيد الافتتاحي"><Input type="number" value={form.initialStock} onChange={(e) => setForm({ ...form, initialStock: e.target.value })} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn onClick={addMaterial}><Plus size={15} /> إضافة</Btn></div>
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
        {data.materials.length === 0 ? <Empty text="لا توجد مواد خام مضافة بعد" /> : (
          <Table headers={canDelete ? ["المادة", "الوحدة", "سعر الوحدة", "الرصيد الحالي", "قيمة المخزون", ""] : ["المادة", "الوحدة", "سعر الوحدة", "الرصيد الحالي", "قيمة المخزون"]}>
            {data.materials.map((m) => {
              const stock = materialStock(m.id, data);
              return (
                <tr key={m.id}>
                  <Td>{m.name}</Td><Td>{m.unit}</Td><Td>{fmt(m.unit_cost)} ر.س</Td>
                  <Td style={{ color: stock < 0 ? C.red : C.text }}>{stock}</Td>
                  <Td>{fmt(stock * m.unit_cost)} ر.س</Td>
                  {canDelete && <Td><button onClick={() => deleteRow("materials", m.id)} style={{ background: "none", border: "none", cursor: "pointer", color: C.red }}><Trash2 size={15} /></button></Td>}
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
function ProductsTab({ data, canDelete, hideProfitInfo, insertRow, deleteRow }) {
  const [form, setForm] = useState({ name: "", sku: "", laborCost: "", overheadCost: "", sellingPrice: "" });
  const [bom, setBom] = useState([]);
  const [bomRow, setBomRow] = useState({ materialId: "", qty: "" });
  const [err, setErr] = useState("");

  function addBomRow() { if (!bomRow.materialId || num(bomRow.qty) <= 0) return; setBom([...bom, { material_id: bomRow.materialId, qty: num(bomRow.qty) }]); setBomRow({ materialId: "", qty: "" }); }
  async function addProduct() {
    if (!form.name.trim()) return setErr("اكتب اسم المنتج");
    if (bom.length === 0) return setErr("أضف مكوّن واحد على الأقل لتركيبة المنتج");
    const e = await insertRow("products", { name: form.name.trim(), sku: form.sku.trim(), bom, labor_cost: num(form.laborCost), overhead_cost: num(form.overheadCost), selling_price: num(form.sellingPrice) });
    if (e) return setErr(e);
    setForm({ name: "", sku: "", laborCost: "", overheadCost: "", sellingPrice: "" }); setBom([]); setErr("");
  }

  return (
    <div>
      <SectionTitle eyebrow="تكلفة المنتج" title="المنتجات وتركيبة التكلفة" icon={<Layers size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>منتج جديد</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginBottom: 14 }}>
          <Field label="اسم المنتج"><Input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="مثال: طاولة زان كلاسيك" /></Field>
          <Field label="كود المنتج (SKU)"><Input value={form.sku} onChange={(e) => setForm({ ...form, sku: e.target.value })} /></Field>
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
            <Table headers={["المادة", "الكمية", "التكلفة"]}>
              {bom.map((r, i) => { const m = data.materials.find((x) => x.id === r.material_id); return (
                <tr key={i}><Td>{m?.name}</Td><Td>{r.qty} {m?.unit}</Td><Td>{fmt((m?.unit_cost || 0) * r.qty)} ر.س</Td></tr>
              ); })}
            </Table>
          </div>
        )}
        <Btn onClick={addProduct}><Plus size={15} /> حفظ المنتج</Btn>
        {err && <Banner>{err}</Banner>}
      </Card>
      <Card>
        {data.products.length === 0 ? <Empty text="لا توجد منتجات مضافة بعد" /> : (
          <Table headers={["المنتج", "تكلفة الخامات", "عمالة", "تكاليف غير مباشرة", "إجمالي التكلفة/وحدة", ...(hideProfitInfo ? [] : ["سعر البيع", "الهامش"]), "المخزون التام", ...(canDelete ? [""] : [])]}>
            {data.products.map((p) => {
              const matCost = bomUnitCost(p, data);
              const unitCost = productUnitCost(p, data);
              const margin = p.selling_price > 0 ? ((p.selling_price - unitCost) / p.selling_price) * 100 : null;
              return (
                <tr key={p.id}>
                  <Td>{p.name}</Td><Td>{fmt(matCost)} ر.س</Td><Td>{fmt(p.labor_cost)} ر.س</Td><Td>{fmt(p.overhead_cost)} ر.س</Td>
                  <Td style={{ fontWeight: 700, color: C.brass }}>{fmt(unitCost)} ر.س</Td>
                  {!hideProfitInfo && (<>
                    <Td>{fmt(p.selling_price)} ر.س</Td>
                    <Td style={{ color: margin == null ? C.muted : margin >= 0 ? C.green : C.red }}>{margin == null ? "—" : `${margin.toFixed(1)}%`}</Td>
                  </>)}
                  <Td>{finishedStock(p.id, data)}</Td>
                  {canDelete && <Td><button onClick={() => deleteRow("products", p.id)} style={{ background: "none", border: "none", cursor: "pointer", color: C.red }}><Trash2 size={15} /></button></Td>}
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
function ProductionTab({ data, insertRow }) {
  const [form, setForm] = useState({ productId: "", qty: "", laborCost: "", overheadCost: "", date: todayStr() });
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
      const need = row.qty * qty;
      const have = materialStock(row.material_id, data);
      if (have < need) { const m = data.materials.find((x) => x.id === row.material_id); missing.push(`${m?.name}: متاح ${have} والمطلوب ${need}`); }
    }
    if (missing.length) return setErr("لا يوجد مخزون كافٍ من: " + missing.join(" · "));
    const materialsCost = bomUnitCost(product, data) * qty;
    const laborCost = num(form.laborCost) || product.labor_cost * qty;
    const overheadCost = num(form.overheadCost) || product.overhead_cost * qty;
    const totalCost = materialsCost + laborCost + overheadCost;
    const e = await insertRow("productionOrders", { product_id: form.productId, qty, materials_cost: materialsCost, labor_cost: laborCost, overhead_cost: overheadCost, total_cost: totalCost, unit_cost: totalCost / qty, order_date: form.date });
    if (e) return setErr(e);
    setOk("تم تسجيل أمر الإنتاج بنجاح، وتم خصم الخامات وإضافة الإنتاج التام");
    setForm({ productId: "", qty: "", laborCost: "", overheadCost: "", date: todayStr() });
  }

  return (
    <div>
      <SectionTitle eyebrow="التصنيع" title="أوامر الإنتاج" icon={<Factory size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>أمر إنتاج جديد</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="المنتج"><Select value={form.productId} onChange={(e) => setForm({ ...form, productId: e.target.value })}><option value="">اختر المنتج</option>{data.products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</Select></Field>
          <Field label="الكمية المطلوب إنتاجها"><Input type="number" value={form.qty} onChange={(e) => setForm({ ...form, qty: e.target.value })} /></Field>
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
          <Table headers={["التاريخ", "المنتج", "الكمية", "تكلفة الخامات", "عمالة", "غير مباشرة", "إجمالي التكلفة", "تكلفة الوحدة"]}>
            {[...data.productionOrders].reverse().map((o) => { const p = data.products.find((x) => x.id === o.product_id); return (
              <tr key={o.id}><Td>{o.order_date}</Td><Td>{p?.name || "—"}</Td><Td>{o.qty}</Td><Td>{fmt(o.materials_cost)}</Td><Td>{fmt(o.labor_cost)}</Td><Td>{fmt(o.overhead_cost)}</Td>
                <Td style={{ fontWeight: 700 }}>{fmt(o.total_cost)} ر.س</Td><Td style={{ color: C.brass }}>{fmt(o.unit_cost)} ر.س</Td></tr>
            ); })}
          </Table>
        )}
      </Card>
    </div>
  );
}

/* ----------------------------------- Sales ---------------------------------- */
function SalesTab({ data, insertRow }) {
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

  return (
    <div>
      <SectionTitle eyebrow="التوزيع" title="المبيعات" icon={<ShoppingCart size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>عملية بيع جديدة</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="المنتج"><Select value={form.productId} onChange={(e) => setForm({ ...form, productId: e.target.value })}><option value="">اختر المنتج</option>{data.products.map((p) => <option key={p.id} value={p.id}>{p.name} (متاح: {finishedStock(p.id, data)})</option>)}</Select></Field>
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
          <Table headers={["التاريخ", "المنتج", "العميل", "الكمية", "سعر الوحدة", "الإجمالي"]}>
            {[...data.sales].reverse().map((s) => { const p = data.products.find((x) => x.id === s.product_id); const c = data.customers.find((x) => x.id === s.customer_id); return (
              <tr key={s.id}><Td>{s.sale_date}</Td><Td>{p?.name || "—"}</Td><Td>{c?.name || "—"}</Td><Td>{s.qty}</Td><Td>{fmt(s.unit_price)} ر.س</Td><Td style={{ fontWeight: 700, color: C.green }}>{fmt(s.total)} ر.س</Td></tr>
            ); })}
          </Table>
        )}
      </Card>
    </div>
  );
}

/* -------------------------------- Suppliers --------------------------------- */
function SuppliersTab({ data, insertRow }) {
  const [name, setName] = useState(""); const [phone, setPhone] = useState("");
  const [payment, setPayment] = useState({ supplierId: "", amount: "", date: todayStr() });
  const [err, setErr] = useState(""); const [expanded, setExpanded] = useState(null);

  async function addSupplier() { if (!name.trim()) return setErr("اكتب اسم المورد"); const e = await insertRow("suppliers", { name: name.trim(), phone: phone.trim() }); if (e) return setErr(e); setName(""); setPhone(""); setErr(""); }
  async function addPayment() {
    if (!payment.supplierId) return setErr("اختر المورد");
    if (num(payment.amount) <= 0) return setErr("أدخل مبلغ أكبر من صفر");
    const e = await insertRow("supplierPayments", { supplier_id: payment.supplierId, amount: num(payment.amount), payment_date: payment.date });
    if (e) return setErr(e);
    setPayment({ supplierId: "", amount: "", date: todayStr() }); setErr("");
  }

  return (
    <div>
      <SectionTitle eyebrow="دفتر أستاذ مساعد" title="الموردين" icon={<Truck size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>مورد جديد</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="اسم المورد"><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label="رقم الهاتف"><Input value={phone} onChange={(e) => setPhone(e.target.value)} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn onClick={addSupplier}><Plus size={15} /> إضافة</Btn></div>
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
        {data.suppliers.length === 0 ? <Empty text="لا يوجد موردون مضافون بعد" /> : (
          <Table headers={["المورد", "الهاتف", "إجمالي المشتريات", "إجمالي المدفوع", "الرصيد المستحق", ""]}>
            {data.suppliers.map((s) => { const bal = supplierBalance(s.id, data); return (
              <React.Fragment key={s.id}>
                <tr>
                  <Td>{s.name}</Td><Td>{s.phone || "—"}</Td><Td>{fmt(supplierPurchaseTotal(s.id, data))} ر.س</Td><Td>{fmt(supplierPaymentTotal(s.id, data))} ر.س</Td>
                  <Td style={{ fontWeight: 700, color: bal > 0 ? C.red : C.green }}>{fmt(bal)} ر.س</Td>
                  <Td><button onClick={() => setExpanded(expanded === s.id ? null : s.id)} style={{ background: "none", border: "none", color: C.brass, cursor: "pointer", fontSize: 12.5 }}>{expanded === s.id ? "إخفاء الحركات" : "عرض الحركات"}</button></Td>
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
  return <Table headers={["التاريخ", "النوع", "البيان", "المبلغ"]}>{rows.map((r, i) => <tr key={i}><Td>{r.date}</Td><Td style={{ color: r.type === "شراء" ? C.red : C.green }}>{r.type}</Td><Td>{r.note || "—"}</Td><Td>{fmt(Math.abs(r.amount))} ر.س</Td></tr>)}</Table>;
}

/* -------------------------------- Customers --------------------------------- */
function CustomersTab({ data, insertRow }) {
  const [name, setName] = useState(""); const [phone, setPhone] = useState("");
  const [receipt, setReceipt] = useState({ customerId: "", amount: "", date: todayStr() });
  const [err, setErr] = useState(""); const [expanded, setExpanded] = useState(null);

  async function addCustomer() { if (!name.trim()) return setErr("اكتب اسم العميل"); const e = await insertRow("customers", { name: name.trim(), phone: phone.trim() }); if (e) return setErr(e); setName(""); setPhone(""); setErr(""); }
  async function addReceipt() {
    if (!receipt.customerId) return setErr("اختر العميل");
    if (num(receipt.amount) <= 0) return setErr("أدخل مبلغ أكبر من صفر");
    const e = await insertRow("customerReceipts", { customer_id: receipt.customerId, amount: num(receipt.amount), receipt_date: receipt.date });
    if (e) return setErr(e);
    setReceipt({ customerId: "", amount: "", date: todayStr() }); setErr("");
  }

  return (
    <div>
      <SectionTitle eyebrow="دفتر أستاذ مساعد" title="العملاء" icon={<Users size={14} />} />
      <Card style={{ marginBottom: 18 }}>
        <div style={{ fontWeight: 700, marginBottom: 12 }}>عميل جديد</div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Field label="اسم العميل"><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label="رقم الهاتف"><Input value={phone} onChange={(e) => setPhone(e.target.value)} /></Field>
        </div>
        <div style={{ marginTop: 12 }}><Btn onClick={addCustomer}><Plus size={15} /> إضافة</Btn></div>
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
        {data.customers.length === 0 ? <Empty text="لا يوجد عملاء مضافون بعد" /> : (
          <Table headers={["العميل", "الهاتف", "إجمالي المبيعات", "إجمالي التحصيل", "الرصيد المستحق", ""]}>
            {data.customers.map((c) => { const bal = customerBalance(c.id, data); return (
              <React.Fragment key={c.id}>
                <tr>
                  <Td>{c.name}</Td><Td>{c.phone || "—"}</Td><Td>{fmt(customerSaleTotal(c.id, data))} ر.س</Td><Td>{fmt(customerReceiptTotal(c.id, data))} ر.س</Td>
                  <Td style={{ fontWeight: 700, color: bal > 0 ? C.brass : C.green }}>{fmt(bal)} ر.س</Td>
                  <Td><button onClick={() => setExpanded(expanded === c.id ? null : c.id)} style={{ background: "none", border: "none", color: C.brass, cursor: "pointer", fontSize: 12.5 }}>{expanded === c.id ? "إخفاء الحركات" : "عرض الحركات"}</button></Td>
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
  const receipts = data.customerReceipts.filter((r) => r.customer_id === customerId).map((r) => ({ date: r.receipt_date, type: "تحصيل", amount: -r.amount, note: r.note }));
  const rows = [...sales, ...receipts].sort((a, b) => (a.date || "").localeCompare(b.date || ""));
  if (rows.length === 0) return <div style={{ color: C.muted, fontSize: 13 }}>لا توجد حركات مسجلة</div>;
  return <Table headers={["التاريخ", "النوع", "البيان", "المبلغ"]}>{rows.map((r, i) => <tr key={i}><Td>{r.date}</Td><Td style={{ color: r.type === "بيع" ? C.brass : C.green }}>{r.type}</Td><Td>{r.note || "—"}</Td><Td>{fmt(Math.abs(r.amount))} ر.س</Td></tr>)}</Table>;
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
  const totals = rows.reduce((a, r) => ({ revenue: a.revenue + r.revenue, cogs: a.cogs + r.cogs, profit: a.profit + r.profit }), { revenue: 0, cogs: 0, profit: 0 });
  const chartData = rows.map((r) => ({ name: r.name.length > 10 ? r.name.slice(0, 10) + "…" : r.name, الربح: Math.round(r.profit) }));

  return (
    <div>
      <SectionTitle eyebrow="الأداء" title="تقارير الربحية" icon={<BarChart3 size={14} />} />
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: 14, marginBottom: 18 }}>
        <Card><div style={{ fontSize: 12.5, color: C.muted, marginBottom: 6 }}>إجمالي الإيرادات</div><div style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 20, color: C.brass }}>{fmt(totals.revenue)} ر.س</div></Card>
        <Card><div style={{ fontSize: 12.5, color: C.muted, marginBottom: 6 }}>إجمالي تكلفة المبيعات</div><div style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 20, color: C.wood }}>{fmt(totals.cogs)} ر.س</div></Card>
        <Card><div style={{ fontSize: 12.5, color: C.muted, marginBottom: 6 }}>صافي الربح</div><div style={{ fontFamily: "Cairo, sans-serif", fontWeight: 800, fontSize: 20, color: totals.profit >= 0 ? C.green : C.red }}>{fmt(totals.profit)} ر.س</div></Card>
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
              <tr key={i}><Td>{r.name}</Td><Td>{r.qtySold}</Td><Td>{fmt(r.revenue)} ر.س</Td><Td>{fmt(r.cogs)} ر.س</Td>
                <Td style={{ fontWeight: 700, color: r.profit >= 0 ? C.green : C.red }}>{fmt(r.profit)} ر.س</Td>
                <Td>{r.margin == null ? "—" : `${r.margin.toFixed(1)}%`}</Td></tr>
            ))}
          </Table>
        )}
      </Card>
    </div>
  );
}
