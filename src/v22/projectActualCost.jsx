import React, { useCallback, useEffect, useMemo, useState } from "react";
import { AlertTriangle, CheckCircle2, Filter, RefreshCw, RotateCcw, Send, ShieldCheck, Wallet, XCircle } from "lucide-react";
import { supabase } from "../supabaseClient";
import { Button, EmptyState, ErrorState, Field, Input, money, Panel, Select, StatCard, SuccessState, TextArea } from "./shared";
import "./projectActualCost.css";

const STATUS_LABELS = { draft:"مسودة", submitted:"مرسلة", approved:"معتمدة", rejected:"مرفوضة", reversed:"معكوسة" };
const CATEGORY_LABELS = { material:"مواد", labor:"عمالة", transport:"نقل", subcontract:"مقاول باطن", rental:"إيجار", asset_consumption:"استهلاك أصول", petty_cash:"مصروفات نثرية", employee_cash_custody:"عهدة نقدية", purchase_invoice:"فاتورة مشتريات", manual_adjustment:"تسوية يدوية", other:"أخرى" };
const SOURCE_LABELS = { purchase_invoice_line:"فاتورة مشتريات", warehouse_issue_line:"صرف مخزن", asset_consumption_line:"استهلاك أصل", factory_labor_allocation:"عمالة مصنع", employee_cash_custody_settlement_line:"تسوية عهدة موظف", petty_cash_settlement_line:"تسوية مصروفات نثرية", manual_adjustment:"تسوية يدوية", legacy_project_cost:"تكلفة قديمة" };

function percent(value) { return value == null ? "—" : `${Number(value || 0).toFixed(1)}%`; }
function toneForRemaining(value) { return Number(value) < 0 ? "negative" : "positive"; }

export function ProjectActualCostTab({ project, profile }) {
  const [snapshot, setSnapshot] = useState(null);
  const [variance, setVariance] = useState(null);
  const [statusFilter, setStatusFilter] = useState("all");
  const [categoryFilter, setCategoryFilter] = useState("all");
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState("");
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");

  const load = useCallback(async () => {
    setLoading(true); setError("");
    const [costResult, varianceResult] = await Promise.all([
      supabase.rpc("get_project_actual_cost_snapshot", { target_project: project.id }),
      supabase.rpc("get_project_cost_variance_snapshot", { target_project: project.id }),
    ]);
    if (costResult.error || varianceResult.error) {
      setError(costResult.error?.message || varianceResult.error?.message || "تعذر تحميل التكلفة الفعلية.");
    } else {
      setSnapshot(costResult.data || { entries:[], approved_total:0, submitted_total:0, by_category:{} });
      setVariance(varianceResult.data || null);
    }
    setLoading(false);
  }, [project.id]);

  useEffect(() => { load(); }, [load]);

  const entries = useMemo(() => {
    const rows = Array.isArray(snapshot?.entries) ? snapshot.entries : [];
    return rows.filter((row) => (statusFilter === "all" || row.status === statusFilter) && (categoryFilter === "all" || row.cost_category === categoryFilter));
  }, [snapshot, statusFilter, categoryFilter]);

  async function runAction(name, row, reason) {
    setBusyId(row.id); setError(""); setSuccess("");
    const args = name === "submit_project_actual_cost" || name === "approve_project_actual_cost"
      ? { target_id: row.id }
      : { target_id: row.id, reason };
    const result = await supabase.rpc(name, args);
    if (result.error) setError(result.error.message);
    else { setSuccess("تم تحديث حالة التكلفة بنجاح."); await load(); }
    setBusyId("");
  }

  function askAndRun(name, row, promptText) {
    const reason = window.prompt(promptText);
    if (reason?.trim()) runAction(name, row, reason.trim());
  }

  if (loading) return <Panel className="actual-cost-loading"><RefreshCw className="spin" size={22}/> جارِ تحميل التكلفة الفعلية...</Panel>;
  if (!snapshot || !variance) return <Panel><ShieldCheck size={28}/><h3>التكلفة الفعلية غير متاحة</h3><ErrorState error={error || "لا تملك صلاحية عرض ماليات هذا المشروع."}/></Panel>;

  const canApprove = ["owner","manager"].includes(profile?.role);
  const isOwner = profile?.role === "owner";

  return <div className="actual-cost-workspace">
    <ErrorState error={error}/><SuccessState message={success}/>

    <div className="actual-cost-kpis">
      <StatCard label="الميزانية المعتمدة" value={money(variance.estimated_cost)}/>
      <StatCard label="التكلفة المعتمدة" value={money(variance.actual_cost)} tone={Number(variance.variance) > 0 ? "negative" : "normal"}/>
      <StatCard label="المتبقي" value={money(variance.remaining_budget)} tone={toneForRemaining(variance.remaining_budget)}/>
      <StatCard label="الانحراف" value={`${money(variance.variance)} · ${percent(variance.variance_percentage)}`} tone={Number(variance.variance) > 0 ? "negative" : "positive"}/>
      <StatCard label="الربح الإجمالي" value={money(variance.gross_profit)} tone={Number(variance.gross_profit) >= 0 ? "positive" : "negative"}/>
      <StatCard label="الهامش" value={percent(variance.gross_margin_percentage)} tone={Number(variance.gross_margin_percentage) >= 0 ? "positive" : "negative"}/>
      <StatCard label="التكلفة المتوقعة عند الإكمال" value={money(variance.forecast_final_cost)} tone={Number(variance.forecast_final_cost) > Number(variance.estimated_cost) ? "negative" : "normal"}/>
      <StatCard label="الربح المتوقع" value={money(variance.forecast_profit)} tone={Number(variance.forecast_profit) >= 0 ? "positive" : "negative"}/>
    </div>

    <Panel className="actual-cost-summary-card">
      <div className="actual-cost-summary-head"><div><h3>حالة التكلفة</h3><p>المعتمد فقط يدخل في تكلفة المشروع، أما المرسل فينتظر الاعتماد.</p></div><Button variant="ghost" onClick={load}><RefreshCw size={15}/> تحديث</Button></div>
      <div className="actual-cost-summary-row"><span><CheckCircle2 size={17}/> معتمد: <b>{money(snapshot.approved_total)}</b></span><span><AlertTriangle size={17}/> بانتظار الاعتماد: <b>{money(snapshot.submitted_total)}</b></span></div>
    </Panel>

    <Panel>
      <div className="actual-cost-toolbar">
        <div><h3>قيود التكلفة الفعلية</h3><p>كل قيد مرتبط بمصدر فريد لمنع التكرار.</p></div>
        <div className="actual-cost-filters"><Filter size={16}/><Select value={statusFilter} onChange={(e)=>setStatusFilter(e.target.value)}><option value="all">كل الحالات</option>{Object.entries(STATUS_LABELS).map(([key,label])=><option key={key} value={key}>{label}</option>)}</Select><Select value={categoryFilter} onChange={(e)=>setCategoryFilter(e.target.value)}><option value="all">كل التصنيفات</option>{Object.entries(CATEGORY_LABELS).map(([key,label])=><option key={key} value={key}>{label}</option>)}</Select></div>
      </div>

      {entries.length === 0 ? <EmptyState title="لا توجد قيود مطابقة" description="ستظهر هنا التكاليف القادمة من المشتريات والمخزن والعمالة والعهد بعد اعتماد مصادرها."/> : <div className="actual-cost-table-wrap"><table className="actual-cost-table"><thead><tr><th>التاريخ</th><th>البيان</th><th>المصدر</th><th>التصنيف</th><th>القيمة</th><th>الحالة</th><th>الإجراءات</th></tr></thead><tbody>{entries.map((row)=><tr key={row.id}><td>{row.cost_date}</td><td><strong>{row.description}</strong><small>{row.source_reference_key}</small></td><td>{SOURCE_LABELS[row.source_type] || row.source_type}</td><td>{CATEGORY_LABELS[row.cost_category] || row.cost_category}</td><td>{money(row.amount)}</td><td><span className={`actual-cost-status ${row.status}`}>{STATUS_LABELS[row.status] || row.status}</span>{row.rejection_reason && <small className="actual-cost-reason">{row.rejection_reason}</small>}{row.reversal_reason && <small className="actual-cost-reason">{row.reversal_reason}</small>}</td><td><div className="actual-cost-actions">{row.status === "draft" && <Button disabled={busyId===row.id} onClick={()=>runAction("submit_project_actual_cost",row)}><Send size={14}/> إرسال</Button>}{row.status === "submitted" && canApprove && <><Button disabled={busyId===row.id} onClick={()=>runAction("approve_project_actual_cost",row)}><CheckCircle2 size={14}/> اعتماد</Button><Button variant="danger" disabled={busyId===row.id} onClick={()=>askAndRun("reject_project_actual_cost",row,"اكتب سبب رفض التكلفة") }><XCircle size={14}/> رفض</Button></>}{row.status === "approved" && isOwner && <Button variant="danger" disabled={busyId===row.id} onClick={()=>askAndRun("reverse_project_actual_cost",row,"اكتب سبب عكس التكلفة المعتمدة") }><RotateCcw size={14}/> عكس</Button>}</div></td></tr>)}</tbody></table></div>}
    </Panel>

    <Panel>
      <h3>المقارنة حسب التصنيف</h3>
      <div className="actual-cost-category-grid">{(variance.categories || []).map((row)=><div key={row.cost_category} className={Number(row.variance)>0?"over":"healthy"}><span>{CATEGORY_LABELS[row.cost_category] || row.cost_category}</span><b>{money(row.actual)} / {money(row.budget)}</b><small>الفرق {money(row.variance)} · {percent(row.variance_percentage)}</small></div>)}</div>
    </Panel>

    <div className="actual-cost-contract-note"><Wallet size={18}/><span>العهدة النقدية وتسليم الأدوات لا يُسجلان كمصروف تلقائيًا؛ الذي يدخل التكلفة هو سطر التسوية أو الاستهلاك المعتمد فقط.</span></div>
  </div>;
}
