import React, { useMemo, useState } from "react";
import { BadgeCheck, Banknote, Clock3, Eye, Pencil, Plus, Send, Trash2, XCircle } from "lucide-react";
import { isAdministrativeRole } from "../identity";
import { supabase } from "../supabaseClient";
import { ArchiveSection } from "../ui";
import {
  Button,
  DataTable,
  EmptyState,
  ErrorState,
  Field,
  Input,
  money,
  number,
  PageTitle,
  Panel,
  PermissionGuard,
  Select,
  StatCard,
  TextArea,
  Toast,
  today,
} from "./shared";
import { calculateDailyLabor } from "./calculations";
import { syncMutation } from "./mutations";

const emptyShift = {
  worker_name: "",
  phone: "",
  trade: "",
  project_id: "",
  work_date: today(),
  start_time: "08:00",
  end_time: "17:00",
  break_minutes: 60,
  hourly_rate: 0,
  overtime_hours: 0,
  overtime_rate: 0,
  addition_amount: 0,
  addition_reason: "",
  deduction_amount: 0,
  deduction_reason: "",
  payment_status: "unpaid",
  notes: "",
};

const PAYMENT_STATUS = { unpaid: "غير مدفوع", partially_paid: "مدفوع جزئيًا", paid: "مدفوع" };
const REVIEW_STATUS = { draft: "بانتظار المراجعة", rejected: "مرفوض", approved: "معتمد" };
const COST_STATUS = { not_posted: "غير مرسلة", submitted: "قيد مراجعة التكلفة", posted: "مرحّلة للتكلفة", rejected: "مرفوضة من التكلفة", reversed: "معكوسة" };

function friendlyError(error) {
  const text = String(error?.message || error || "");
  if (text.includes("Rejection reason")) return "سبب الرفض مطلوب.";
  if (text.includes("must be approved before payment")) return "لا يمكن الدفع قبل اعتماد الوردية.";
  if (text.includes("already paid")) return "تم دفع هذه الوردية بالفعل.";
  if (text.includes("cannot be reviewed again")) return "لا يمكن إعادة مراجعة وردية مدفوعة.";
  if (text.includes("must be corrected before review")) return "يجب تصحيح الوردية المرفوضة قبل إعادة المراجعة.";
  if (text.includes("Only draft daily labor shifts")) return "المراجعة متاحة للمسودات فقط.";
  if (text.includes("Correction reason")) return "سبب التصحيح مطلوب.";
  if (text.includes("Only rejected daily labor shifts")) return "التصحيح متاح للورديات المرفوضة فقط.";
  if (text.includes("Posted daily labor shift")) return "لا يمكن تصحيح وردية مرتبطة بتكلفة مشروع.";
  if (text.includes("Complete corrected shift details")) return "بيانات الوردية المصححة غير مكتملة.";
  if (text.includes("must be approved before Actual Cost")) return "يجب اعتماد الوردية قبل إرسالها للتكلفة الفعلية.";
  if (text.includes("already in the Actual Cost workflow") || text.includes("already linked to an Actual Cost")) return "الوردية مرتبطة بالفعل بمسار التكلفة الفعلية.";
  if (text.includes("must be linked to a project")) return "يجب ربط الوردية بمشروع قبل إرسالها للتكلفة الفعلية.";
  if (text.includes("Owner, manager, or accountant")) return "إرسال التكلفة متاح للمالك أو المدير أو المحاسب فقط.";
  if (text.includes("cannot be deleted")) return "لا يمكن حذف وردية تمت مراجعتها أو دفعها أو ربطها بتكلفة مشروع.";
  if (text.includes("permission required")) return "ليس لديك الصلاحية المطلوبة لتنفيذ الإجراء.";
  return text || "تعذر تنفيذ الإجراء.";
}

function Info({ label, value }) {
  return <div><small>{label}</small><strong className="table-sub">{value}</strong></div>;
}

export function DailyLaborForm({ projects, profile, canSeeMoney, onSaved, onCancel, initialShift = null, correctionReason = "", onCorrectionReasonChange, onCorrect, busy = false }) {
  const [form, setForm] = useState(() => ({
    ...emptyShift,
    ...(initialShift || {}),
    project_id: initialShift?.project_id || "",
    phone: initialShift?.phone || "",
    trade: initialShift?.trade || "",
    addition_reason: initialShift?.addition_reason || "",
    deduction_reason: initialShift?.deduction_reason || "",
    notes: initialShift?.notes || "",
    start_time: initialShift?.start_time?.slice(0, 5) || emptyShift.start_time,
    end_time: initialShift?.end_time?.slice(0, 5) || emptyShift.end_time,
  }));
  const [error, setError] = useState("");
  const calculation = calculateDailyLabor(form);

  async function submit(event) {
    event.preventDefault();
    setError("");
    if (onCorrect && !correctionReason.trim()) return setError("سبب التصحيح مطلوب.");
    if (canSeeMoney && number(form.addition_amount) > 0 && !form.addition_reason.trim()) return setError("سبب الإضافة مطلوب.");
    if (canSeeMoney && number(form.deduction_amount) > 0 && !form.deduction_reason.trim()) return setError("سبب الخصم مطلوب.");
    if (canSeeMoney && number(form.deduction_amount) > calculation.totalAmount + number(form.addition_amount)) return setError("الخصم لا يمكن أن يتجاوز الإجمالي بعد الإضافات.");
    const payload = {
      worker_name: form.worker_name.trim(),
      phone: form.phone?.trim() || "",
      trade: form.trade?.trim() || "",
      project_id: form.project_id || null,
      work_date: form.work_date,
      start_time: form.start_time,
      end_time: form.end_time,
      break_minutes: number(form.break_minutes),
      hourly_rate: canSeeMoney ? number(form.hourly_rate) : 0,
      overtime_hours: number(form.overtime_hours),
      overtime_rate: canSeeMoney ? number(form.overtime_rate) : 0,
      addition_amount: canSeeMoney ? number(form.addition_amount) : 0,
      addition_reason: canSeeMoney && number(form.addition_amount) > 0 ? form.addition_reason.trim() : "",
      deduction_amount: canSeeMoney ? number(form.deduction_amount) : 0,
      deduction_reason: canSeeMoney && number(form.deduction_amount) > 0 ? form.deduction_reason.trim() : "",
      notes: form.notes?.trim() || "",
    };
    if (onCorrect) {
      const result = await onCorrect(payload, correctionReason.trim());
      if (result?.error) setError(friendlyError(result.error));
      return;
    }
    const mutationResult = await supabase.from("daily_labor").insert({
      ...payload,
      addition_reason: payload.addition_reason || null,
      deduction_reason: payload.deduction_reason || null,
      notes: payload.notes || null,
      total_hours: calculation.totalHours,
      total_amount: calculation.totalAmount,
      review_status: "draft",
      created_by: profile.id,
    });
    const result = await syncMutation({ scope: "dailyLabor:create", mutationResult, refetch: onSaved });
    if (result.error) setError(friendlyError(result.error));
  }

  return <form onSubmit={submit}>
    <div className="v22-form-grid">
      <Field label="اسم العامل"><Input required value={form.worker_name} onChange={(e) => setForm({ ...form, worker_name: e.target.value })}/></Field>
      <Field label="الهاتف"><Input value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })}/></Field>
      <Field label="الحرفة"><Input value={form.trade} onChange={(e) => setForm({ ...form, trade: e.target.value })}/></Field>
      <Field label="المشروع"><Select value={form.project_id} onChange={(e) => setForm({ ...form, project_id: e.target.value })}><option value="">بدون مشروع</option>{projects.map((project) => <option key={project.id} value={project.id}>{project.project_code} · {project.project_name}</option>)}</Select></Field>
      <Field label="تاريخ العمل"><Input required type="date" value={form.work_date} onChange={(e) => setForm({ ...form, work_date: e.target.value })}/></Field>
      <Field label="بداية الوردية"><Input required type="time" value={form.start_time} onChange={(e) => setForm({ ...form, start_time: e.target.value })}/></Field>
      <Field label="نهاية الوردية"><Input required type="time" value={form.end_time} onChange={(e) => setForm({ ...form, end_time: e.target.value })}/></Field>
      <Field label="الراحة بالدقائق"><Input type="number" min="0" value={form.break_minutes} onChange={(e) => setForm({ ...form, break_minutes: e.target.value })}/></Field>
      <PermissionGuard allow={canSeeMoney}>
        <Field label="سعر الساعة"><Input type="number" min="0" value={form.hourly_rate} onChange={(e) => setForm({ ...form, hourly_rate: e.target.value })}/></Field>
        <Field label="سعر الساعة الإضافية"><Input type="number" min="0" value={form.overtime_rate} onChange={(e) => setForm({ ...form, overtime_rate: e.target.value })}/></Field>
        <Field label="إضافات"><Input type="number" min="0" value={form.addition_amount} onChange={(e) => setForm({ ...form, addition_amount: e.target.value })}/></Field>
        <Field label="سبب الإضافة"><Input required={number(form.addition_amount) > 0} value={form.addition_reason} onChange={(e) => setForm({ ...form, addition_reason: e.target.value })}/></Field>
        <Field label="خصومات"><Input type="number" min="0" value={form.deduction_amount} onChange={(e) => setForm({ ...form, deduction_amount: e.target.value })}/></Field>
        <Field label="سبب الخصم"><Input required={number(form.deduction_amount) > 0} value={form.deduction_reason} onChange={(e) => setForm({ ...form, deduction_reason: e.target.value })}/></Field>
      </PermissionGuard>
      <Field label="ساعات إضافية"><Input type="number" min="0" step=".25" value={form.overtime_hours} onChange={(e) => setForm({ ...form, overtime_hours: e.target.value })}/></Field>
      <Field label="ملاحظات" wide><TextArea value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })}/></Field>
      {onCorrect && <Field label="سبب التصحيح" wide><TextArea required value={correctionReason} onChange={(e) => onCorrectionReasonChange(e.target.value)} placeholder="اشرح الخطأ الذي تم تصحيحه..."/></Field>}
    </div>
    <div className="labor-calculation"><span><Clock3 size={15}/> إجمالي الساعات <b>{calculation.totalHours}</b></span>{canSeeMoney && <><span>الإجمالي <b>{money(calculation.totalAmount)}</b></span><span>صافي التسوية <b>{money(calculation.totalAmount + number(form.addition_amount) - number(form.deduction_amount))}</b></span></>}</div>
    <ErrorState error={error}/>
    <div className="v22-actions modal-actions"><Button type="button" variant="ghost" disabled={busy} onClick={onCancel}>إلغاء</Button><Button disabled={busy}>{onCorrect ? "حفظ التصحيح وإعادة المراجعة" : "حفظ الوردية"}</Button></div>
  </form>;
}

export function DailyLaborTab({ data, profile, permissions, refresh }) {
  const [showForm, setShowForm] = useState(false);
  const [selected, setSelected] = useState(null);
  const [reviewAction, setReviewAction] = useState(null);
  const [reviewReason, setReviewReason] = useState("");
  const [paymentAction, setPaymentAction] = useState(null);
  const [paymentReference, setPaymentReference] = useState("");
  const [paymentNotes, setPaymentNotes] = useState("");
  const [correctionAction, setCorrectionAction] = useState(null);
  const [correctionReason, setCorrectionReason] = useState("");
  const [correctionHistory, setCorrectionHistory] = useState([]);
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [project, setProject] = useState("");
  const [group, setGroup] = useState("none");
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const [busy, setBusy] = useState(false);
  const canSeeMoney = profile.role !== "production";
  const canReview = isAdministrativeRole(profile.role) || permissions.daily_labor_edit;
  const canCorrect = canSeeMoney && canReview;
  const canSubmitActualCost = ["owner", "manager", "accountant"].includes(profile.role);

  const rows = useMemo(() => data.dailyLabor
    .filter((row) => (!from || row.work_date >= from) && (!to || row.work_date <= to) && (!project || row.project_id === project))
    .sort((a, b) => b.work_date.localeCompare(a.work_date)), [data.dailyLabor, from, to, project]);

  const activeRows = useMemo(() => rows.filter((row) =>
    row.review_status !== "rejected"
    && row.payment_status !== "paid"
    && !["posted", "reversed"].includes(row.cost_posting_status)
  ), [rows]);
  const archivedRows = useMemo(() => rows.filter((row) => !activeRows.includes(row)), [rows, activeRows]);

  const summary = useMemo(() => activeRows.reduce((acc, row) => ({
    hours: acc.hours + number(row.total_hours),
    total: acc.total + number(row.net_amount ?? row.total_amount),
    paid: acc.paid + number(row.paid_amount),
    unpaid: acc.unpaid + Math.max(0, number(row.net_amount ?? row.total_amount) - number(row.paid_amount)),
  }), { hours: 0, total: 0, paid: 0, unpaid: 0 }), [activeRows]);

  const grouped = useMemo(() => group === "none" ? [["الورديات النشطة", activeRows]] : Object.entries(activeRows.reduce((acc, row) => {
    const key = group === "worker" ? row.worker_name : (data.projects.find((item) => item.id === row.project_id)?.project_name || "بدون مشروع");
    (acc[key] ??= []).push(row);
    return acc;
  }, {})), [activeRows, group, data.projects]);

  async function loadCorrectionHistory(shiftId) {
    const result = await supabase.rpc("get_daily_labor_corrections", { target_shift_id: shiftId });
    if (result.error) {
      setCorrectionHistory([]);
      setError(friendlyError(result.error));
      return;
    }
    setCorrectionHistory(result.data || []);
  }

  async function openDetails(row) {
    setSelected(row);
    setCorrectionHistory([]);
    if (number(row.correction_count) > 0) await loadCorrectionHistory(row.id);
  }

  async function reviewShift(approve) {
    setError("");
    if (!approve && !reviewReason.trim()) return setError("سبب الرفض مطلوب.");
    setBusy(true);
    const result = await supabase.rpc("review_daily_labor", {
      target_shift_id: reviewAction.id,
      approve,
      reason: approve ? null : reviewReason.trim(),
    });
    if (!result.error) await refresh("dailyLabor");
    setBusy(false);
    if (result.error) return setError(friendlyError(result.error));
    setSelected(result.data.shift);
    setReviewAction(null);
    setReviewReason("");
    setSuccess(approve ? "تم اعتماد الوردية بعد مراجعة تفاصيلها." : "تم رفض الوردية وتسجيل السبب.");
  }

  async function payShift(event) {
    event.preventDefault();
    setError("");
    setBusy(true);
    const result = await supabase.rpc("pay_daily_labor", {
      target_shift_id: paymentAction.id,
      reference: paymentReference.trim() || null,
      notes: paymentNotes.trim() || null,
    });
    if (!result.error) await refresh("dailyLabor");
    setBusy(false);
    if (result.error) return setError(friendlyError(result.error));
    setSelected(result.data.shift);
    setPaymentAction(null);
    setPaymentReference("");
    setPaymentNotes("");
    setSuccess("تم تسجيل دفع مستحق العامل مع مرجع الدفع.");
  }

  async function correctShift(payload, reason) {
    setError("");
    setBusy(true);
    const result = await supabase.rpc("correct_daily_labor", {
      target_shift_id: correctionAction.id,
      correction_reason: reason,
      payload,
    });
    if (!result.error) await refresh("dailyLabor");
    setBusy(false);
    if (result.error) return result;
    setCorrectionAction(null);
    setCorrectionReason("");
    setSelected(result.data.shift);
    await loadCorrectionHistory(result.data.shift.id);
    setSuccess("تم حفظ التصحيح وإعادة الوردية لمسار المراجعة.");
    return result;
  }

  async function submitActualCost(row) {
    setError("");
    setBusy(true);
    const result = await supabase.rpc("prepare_operational_source_actual_cost", {
      target_source_type: "daily_labor",
      target_source_id: row.id,
    });
    if (!result.error) await refresh("dailyLabor");
    setBusy(false);
    if (result.error) return setError(friendlyError(result.error));
    setSelected(null);
    setSuccess("تم إرسال صافي التسوية للتكلفة الفعلية، وينتظر اعتماد المدير.");
  }

  async function remove(row) {
    if (!window.confirm(`حذف مسودة وردية ${row.worker_name}؟`)) return;
    setError("");
    const mutationResult = await supabase.from("daily_labor").delete().eq("id", row.id);
    const result = await syncMutation({ scope: "dailyLabor:delete", mutationResult, refetch: () => refresh("dailyLabor") });
    if (result.error) return setError(friendlyError(result.error));
    setSuccess("تم حذف مسودة الوردية بنجاح");
  }

  return <div>
    <PageTitle eyebrow="تكلفة العمل المؤقت" title="العمالة اليومية" description="راجع تفاصيل كل وردية وطريقة حسابها قبل الاعتماد أو الدفع." actions={<PermissionGuard allow={permissions.daily_labor_create}><Button onClick={() => setShowForm(true)}><Plus size={16}/> إضافة وردية</Button></PermissionGuard>}/>
    <ErrorState error={error}/>
    <div className={`v22-grid ${canSeeMoney ? "cols-5" : "cols-2"} labor-stats`}>
      <StatCard label="ساعات العمل" value={`${summary.hours.toFixed(2)} ساعة`}/>
      {canSeeMoney && <><StatCard label="صافي مستحقات العمالة" value={money(summary.total)}/><StatCard label="المدفوع" value={money(summary.paid)} tone="positive"/><StatCard label="غير المدفوع" value={money(summary.unpaid)} tone="negative"/></>}
      <StatCard label="الورديات النشطة" value={activeRows.length}/>
    </div>
    <Panel>
      <div className="v22-filters">
        <Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} aria-label="من"/>
        <Input type="date" value={to} onChange={(e) => setTo(e.target.value)} aria-label="إلى"/>
        <Select value={project} onChange={(e) => setProject(e.target.value)}><option value="">كل المشاريع</option>{data.projects.map((item) => <option key={item.id} value={item.id}>{item.project_name}</option>)}</Select>
        <Select value={group} onChange={(e) => setGroup(e.target.value)}><option value="none">بدون تجميع</option><option value="worker">تجميع حسب العامل</option><option value="project">تجميع حسب المشروع</option></Select>
      </div>
      {activeRows.length ? grouped.map(([label, items]) => <div className="labor-group" key={label}>
        <h3>{label}<span>{items.length} وردية</span></h3>
        <DataTable headers={canSeeMoney ? ["العامل", "المشروع", "التاريخ", "الساعات", "الإجمالي", "المراجعة", "الدفع", "إجراءات"] : ["العامل", "المشروع", "التاريخ", "الساعات", "المراجعة", "إجراءات"]}>
          {items.map((row) => <tr key={row.id}>
            <td><strong>{row.worker_name}</strong><br/><small>{row.trade || "—"}</small></td>
            <td>{data.projects.find((item) => item.id === row.project_id)?.project_name || "—"}</td>
            <td>{row.work_date}<br/><small>{row.start_time?.slice(0, 5)} — {row.end_time?.slice(0, 5)}</small></td>
            <td>{row.total_hours}</td>
            {canSeeMoney && <td><strong>{money(row.net_amount ?? row.total_amount)}</strong></td>}
            <td><span className={`payroll-status ${row.review_status || "draft"}`}>{REVIEW_STATUS[row.review_status || "draft"]}</span></td>
            {canSeeMoney && <td><span className={`payroll-status ${row.payment_status}`}>{PAYMENT_STATUS[row.payment_status]}</span></td>}
            <td><div className="v22-actions">
              <Button variant="ghost" onClick={() => openDetails(row)}><Eye size={14}/> فتح التفاصيل</Button>
              {permissions.daily_labor_delete && (row.review_status || "draft") === "draft" && row.payment_status !== "paid" && !row.actual_cost_entry_id && number(row.correction_count) === 0 && <button className="v22-icon-button danger" onClick={() => remove(row)}><Trash2 size={15}/></button>}
            </div></td>
          </tr>)}
        </DataTable>
      </div>) : <EmptyState title="لا توجد ورديات نشطة مطابقة"/>}
    </Panel>

    <ArchiveSection title="سجل الورديات المكتملة والمرفوضة" count={archivedRows.length} helpText="الورديات المدفوعة أو المرفوضة أو المرحلة للتكلفة محفوظة هنا ولا تزاحم العمل الجاري.">
      {archivedRows.length ? <DataTable headers={canSeeMoney ? ["العامل", "المشروع", "التاريخ", "الساعات", "الإجمالي", "المراجعة", "الدفع", "إجراءات"] : ["العامل", "المشروع", "التاريخ", "الساعات", "المراجعة", "إجراءات"]}>
        {archivedRows.map((row) => <tr key={row.id}>
          <td><strong>{row.worker_name}</strong><br/><small>{row.trade || "—"}</small></td>
          <td>{data.projects.find((item) => item.id === row.project_id)?.project_name || "—"}</td>
          <td>{row.work_date}<br/><small>{row.start_time?.slice(0, 5)} — {row.end_time?.slice(0, 5)}</small></td>
          <td>{row.total_hours}</td>
          {canSeeMoney && <td><strong>{money(row.net_amount ?? row.total_amount)}</strong></td>}
          <td><span className={`payroll-status ${row.review_status || "draft"}`}>{REVIEW_STATUS[row.review_status || "draft"]}</span></td>
          {canSeeMoney && <td><span className={`payroll-status ${row.payment_status}`}>{PAYMENT_STATUS[row.payment_status]}</span></td>}
          <td><Button variant="ghost" onClick={() => openDetails(row)}><Eye size={14}/> فتح التفاصيل</Button></td>
        </tr>)}
      </DataTable> : <EmptyState title="لا توجد ورديات في السجل"/>}
    </ArchiveSection>

    {showForm && <div className="v22-modal-backdrop"><div className="v22-modal"><h3>تسجيل وردية يومية</h3><DailyLaborForm projects={data.projects} profile={profile} canSeeMoney={canSeeMoney} onCancel={() => setShowForm(false)} onSaved={async () => { const refetchResult = await refresh("dailyLabor"); if (!refetchResult?.error) { setShowForm(false); setSuccess("تم حفظ الوردية بنجاح"); } return refetchResult; }}/></div></div>}

    {selected && <div className="v22-modal-backdrop"><div className="v22-modal">
      <h3>تفاصيل وردية العمالة الخارجية</h3>
      <div className="v22-form-grid">
        <Info label="العامل" value={selected.worker_name}/><Info label="الهاتف" value={selected.phone || "—"}/><Info label="الحرفة" value={selected.trade || "—"}/><Info label="المشروع" value={data.projects.find((item) => item.id === selected.project_id)?.project_name || "بدون مشروع"}/>
        <Info label="تاريخ العمل" value={selected.work_date}/><Info label="بداية الوردية" value={selected.start_time?.slice(0, 5)}/><Info label="نهاية الوردية" value={selected.end_time?.slice(0, 5)}/><Info label="الراحة" value={`${number(selected.break_minutes)} دقيقة`}/>
        <Info label="الساعات الفعلية" value={`${number(selected.total_hours).toFixed(2)} ساعة`}/><Info label="الساعات الإضافية" value={`${number(selected.overtime_hours).toFixed(2)} ساعة`}/>{canSeeMoney && <><Info label="سعر الساعة" value={money(selected.hourly_rate)}/><Info label="سعر الإضافي" value={money(selected.overtime_rate)}/><Info label="الإجمالي المحتسب" value={money(selected.total_amount)}/><Info label="الإضافات" value={money(selected.addition_amount)}/>{number(selected.addition_amount) > 0 && <Info label="سبب الإضافة" value={selected.addition_reason}/>}<Info label="الخصومات" value={money(selected.deduction_amount)}/>{number(selected.deduction_amount) > 0 && <Info label="سبب الخصم" value={selected.deduction_reason}/>}<Info label="صافي التسوية" value={money(selected.net_amount ?? selected.total_amount)}/><Info label="المدفوع" value={money(selected.paid_amount)}/></>}
        <Info label="حالة المراجعة" value={REVIEW_STATUS[selected.review_status || "draft"]}/><Info label="حالة الدفع" value={PAYMENT_STATUS[selected.payment_status]}/>
        {canSeeMoney && <Info label="حالة التكلفة الفعلية" value={COST_STATUS[selected.cost_posting_status || "not_posted"] || selected.cost_posting_status}/>}
        {number(selected.correction_count) > 0 && <><Info label="عدد التصحيحات" value={number(selected.correction_count)}/><Info label="آخر سبب تصحيح" value={selected.last_correction_reason || "—"}/></>}
        {selected.rejection_reason && <Info label="سبب الرفض" value={selected.rejection_reason}/>} {selected.payment_reference && <Info label="مرجع الدفع" value={selected.payment_reference}/>} {selected.payment_notes && <Info label="ملاحظات الدفع" value={selected.payment_notes}/>} {selected.notes && <Info label="ملاحظات الوردية" value={selected.notes}/>} 
      </div>
      {correctionHistory.length > 0 && <div className="labor-correction-history"><h4>سجل التصحيحات</h4>{correctionHistory.map((item) => <div key={item.number}><strong>تصحيح #{item.number}</strong><span>{item.reason}</span><small>{item.corrected_by_name} · {new Date(item.corrected_at).toLocaleString("ar-EG")}</small></div>)}</div>}
      <div className="v22-alert info">طريقة الحساب: الساعات الفعلية × سعر الساعة + الساعات الإضافية × سعر الإضافي. راجع التوقيت والراحة والأسعار قبل الاعتماد.</div>
      {canSubmitActualCost && selected.review_status === "approved" && selected.project_id && (selected.cost_posting_status || "not_posted") === "not_posted" && !selected.actual_cost_entry_id && <div className="v22-alert info">إرسال التكلفة ينشئ قيدًا بصافي التسوية فقط في حالة «قيد المراجعة»؛ لا يتم اعتماده أو إضافته لتكلفة المشروع تلقائيًا.</div>}
      <div className="v22-actions modal-actions">
        {canReview && (selected.review_status || "draft") === "draft" && selected.payment_status !== "paid" && <><Button variant="danger" onClick={() => { setReviewAction(selected); setReviewReason(""); setSelected(null); }}><XCircle size={14}/> رفض</Button><Button onClick={() => { setReviewAction(selected); setReviewReason(""); setSelected(null); }}><BadgeCheck size={14}/> اعتماد</Button></>}
        {canCorrect && selected.review_status === "rejected" && selected.payment_status === "unpaid" && !selected.actual_cost_entry_id && selected.cost_posting_status === "not_posted" && <Button onClick={() => { setCorrectionAction(selected); setCorrectionReason(""); setSelected(null); }}><Pencil size={14}/> تصحيح الوردية</Button>}
        {canSeeMoney && permissions.daily_labor_pay && selected.review_status === "approved" && selected.payment_status !== "paid" && <Button onClick={() => { setPaymentAction(selected); setSelected(null); }}><Banknote size={14}/> تسجيل الدفع</Button>}
        {canSubmitActualCost && selected.review_status === "approved" && selected.project_id && (selected.cost_posting_status || "not_posted") === "not_posted" && !selected.actual_cost_entry_id && <Button disabled={busy} onClick={() => submitActualCost(selected)}><Send size={14}/> إرسال للتكلفة الفعلية</Button>}
        <Button variant="ghost" onClick={() => setSelected(null)}>إغلاق</Button>
      </div>
    </div></div>}

    {correctionAction && <div className="v22-modal-backdrop"><div className="v22-modal">
      <h3>تصحيح وردية مرفوضة</h3>
      <p>سيُحفظ الوضع السابق كاملًا في سجل غير قابل للحذف، ثم تعود الوردية لمسودة تحتاج اعتمادًا جديدًا.</p>
      <DailyLaborForm projects={data.projects} profile={profile} canSeeMoney={canSeeMoney} initialShift={correctionAction} correctionReason={correctionReason} onCorrectionReasonChange={setCorrectionReason} onCorrect={correctShift} busy={busy} onCancel={() => { setCorrectionAction(null); setCorrectionReason(""); }}/>
      {busy && <div className="v22-alert info">جارٍ حفظ التصحيح...</div>}
    </div></div>}

    {reviewAction && <div className="v22-modal-backdrop"><div className="v22-modal">
      <h3>قرار مراجعة الوردية</h3>
      <p>اعتماد الوردية يسمح للحسابات بتسجيل الدفع. عند الرفض يجب كتابة السبب.</p>
      <Field label="سبب الرفض"><TextArea value={reviewReason} onChange={(e) => setReviewReason(e.target.value)} placeholder="اكتب السبب عند الرفض..."/></Field>
      <div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={() => setReviewAction(null)}>رجوع</Button><Button variant="danger" disabled={busy} onClick={() => reviewShift(false)}><XCircle size={14}/> رفض</Button><Button disabled={busy} onClick={() => reviewShift(true)}><BadgeCheck size={14}/> اعتماد</Button></div>
    </div></div>}

    {paymentAction && <div className="v22-modal-backdrop"><form className="v22-modal" onSubmit={payShift}>
      <h3>تسجيل دفع مستحق العامل</h3>
      <p>سيتم تسجيل دفع صافي التسوية {money(paymentAction.net_amount ?? paymentAction.total_amount)} للعامل {paymentAction.worker_name} بعد اعتماده.</p>
      <Field label="مرجع الدفع"><Input value={paymentReference} onChange={(e) => setPaymentReference(e.target.value)} placeholder="رقم التحويل أو السند..."/></Field>
      <Field label="ملاحظات الدفع"><TextArea value={paymentNotes} onChange={(e) => setPaymentNotes(e.target.value)} placeholder="أي تفاصيل تساعد المراجعة لاحقًا..."/></Field>
      <div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={() => setPaymentAction(null)}>رجوع</Button><Button disabled={busy}><Banknote size={14}/> تأكيد الدفع</Button></div>
    </form></div>}

    <Toast message={success} onDismiss={() => setSuccess("")}/>
  </div>;
}
