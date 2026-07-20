import React, { useCallback, useEffect, useMemo, useState } from "react";
import { BarChart3, RefreshCw } from "lucide-react";
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { supabase } from "../supabaseClient";

const css = {
  panel: { background: "var(--color-surface)", border: "1px solid var(--color-border)", borderRadius: "var(--radius-lg)", boxShadow: "var(--shadow-sm)", padding: 18 },
  grid: { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(190px, 1fr))", gap: 14 },
  muted: { color: "var(--color-text-muted)" },
};

function defaultRange() {
  const end = new Date();
  const start = new Date(end.getFullYear(), end.getMonth() - 11, 1);
  return { from: start.toISOString().slice(0, 10), to: end.toISOString().slice(0, 10) };
}

function money(value, currency) {
  return new Intl.NumberFormat(currency?.locale || "ar-SA", {
    style: "currency",
    currency: currency?.code || "SAR",
    minimumFractionDigits: currency?.decimal_places ?? 2,
    maximumFractionDigits: currency?.decimal_places ?? 2,
  }).format(Number(value || 0));
}

function Metric({ label, value, tone = "var(--color-text)" }) {
  return <div style={css.panel}><div style={{ ...css.muted, fontSize: 12.5 }}>{label}</div><div style={{ color: tone, fontWeight: 800, fontSize: 22, marginTop: 7 }}>{value}</div></div>;
}

export function ReportingWorkspace() {
  const [range, setRange] = useState(defaultRange);
  const [report, setReport] = useState(null);
  const [state, setState] = useState({ loading: true, error: "" });

  const load = useCallback(async () => {
    setState({ loading: true, error: "" });
    const { data, error } = await supabase.rpc("get_reporting_workspace", { date_from: range.from, date_to: range.to });
    if (error) {
      setReport(null);
      setState({ loading: false, error: error.message || "تعذر تحميل التقارير." });
      return;
    }
    setReport(data);
    setState({ loading: false, error: "" });
  }, [range.from, range.to]);

  useEffect(() => { load(); }, [load]);

  const chartData = useMemo(() => (report?.actual_cost_by_month || []).map((row) => ({
    month: String(row.period_month || "").slice(0, 7),
    amount: Number(row.amount || 0),
  })), [report]);

  const s = report?.summary || {};
  const currency = report?.currency;

  return <div>
    <header className="page-header">
      <div className="page-header-copy">
        <div className="page-eyebrow"><BarChart3 size={14} /><span>الأداء</span></div>
        <h2>التقارير والتحليلات</h2>
        <p>مؤشرات مالية وتشغيلية موحدة من مصادر النظام الأصلية بصلاحيات محمية.</p>
      </div>
    </header>

    <div style={{ ...css.panel, marginBottom: 18, display: "flex", gap: 12, alignItems: "end", flexWrap: "wrap" }}>
      <label style={{ ...css.muted, display: "grid", gap: 5 }}>من<input type="date" value={range.from} onChange={(e) => setRange((r) => ({ ...r, from: e.target.value }))} /></label>
      <label style={{ ...css.muted, display: "grid", gap: 5 }}>إلى<input type="date" value={range.to} onChange={(e) => setRange((r) => ({ ...r, to: e.target.value }))} /></label>
      <button type="button" onClick={load} disabled={state.loading} style={{ display: "inline-flex", alignItems: "center", gap: 6 }}><RefreshCw size={15} /> تحديث</button>
      {report?.generated_at && <span style={{ ...css.muted, fontSize: 12 }}>آخر توليد: {new Date(report.generated_at).toLocaleString("ar-SA")}</span>}
    </div>

    {state.loading && <div style={css.panel}>جارِ تحميل التقرير المحمي…</div>}
    {state.error && <div role="alert" style={{ ...css.panel, color: "var(--color-danger)" }}>{state.error.includes("Financial reporting access required") ? "لا تملك صلاحية عرض التقارير المالية." : state.error}</div>}

    {report && <>
      <div style={{ ...css.grid, marginBottom: 18 }}>
        <Metric label="المشاريع النشطة" value={s.projects_active || 0} />
        <Metric label="المشاريع المتأخرة" value={s.projects_delayed || 0} tone="var(--color-danger)" />
        <Metric label="الميزانية المعتمدة" value={money(s.approved_budget, currency)} />
        <Metric label="التكلفة الفعلية المعتمدة" value={money(s.approved_actual_cost, currency)} />
        <Metric label="إيراد المشاريع" value={money(s.project_revenue, currency)} tone="var(--color-success)" />
        <Metric label="قيمة المخزون" value={money(s.inventory_value, currency)} />
        <Metric label="أوامر الإنتاج المفتوحة" value={s.production_orders_open || 0} />
        <Metric label="فواتير الموردين المستحقة" value={s.supplier_invoices_due || 0} tone="var(--color-danger)" />
        <Metric label="الرواتب المعلقة" value={s.payroll_pending || 0} />
        <Metric label="العهد المتأخرة" value={s.custody_overdue || 0} tone="var(--color-danger)" />
      </div>

      <div style={{ ...css.panel, marginBottom: 18 }}>
        <h3>التكلفة الفعلية حسب الشهر</h3>
        {chartData.length === 0 ? <p style={css.muted}>لا توجد تكاليف معتمدة داخل الفترة.</p> : <ResponsiveContainer width="100%" height={260}><BarChart data={chartData}><CartesianGrid stroke="var(--color-border)" strokeDasharray="3 3" /><XAxis dataKey="month" /><YAxis /><Tooltip formatter={(value) => money(value, currency)} /><Bar dataKey="amount" radius={[4, 4, 0, 0]} fill="var(--color-gold)" /></BarChart></ResponsiveContainer>}
      </div>

      <div style={{ ...css.panel, overflowX: "auto" }}>
        <h3>ربحية المشاريع</h3>
        {(report.projects || []).length === 0 ? <p style={css.muted}>لا توجد مشاريع متاحة.</p> : <table style={{ width: "100%", borderCollapse: "collapse" }}><thead><tr>{["الكود", "المشروع", "الحالة", "الإيراد", "الميزانية", "التكلفة الفعلية", "مجمل الربح", "الهامش"].map((h) => <th key={h} style={{ textAlign: "right", padding: 9, borderBottom: "1px solid var(--color-border)" }}>{h}</th>)}</tr></thead><tbody>{report.projects.map((row) => <tr key={row.id}><td>{row.project_code}</td><td>{row.project_name}</td><td>{row.lifecycle}</td><td>{money(row.revenue, currency)}</td><td>{money(row.approved_budget, currency)}</td><td>{money(row.approved_actual_cost, currency)}</td><td>{money(row.gross_profit, currency)}</td><td>{row.margin_percentage == null ? "—" : `${row.margin_percentage}%`}</td></tr>)}</tbody></table>}
      </div>
    </>}
  </div>;
}
