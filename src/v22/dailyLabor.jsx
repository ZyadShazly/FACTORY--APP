import React, { useMemo, useState } from "react";
import { BadgeCheck, Banknote, Clock3, Eye, Plus, Trash2, XCircle } from "lucide-react";
import { isAdministrativeRole } from "../identity";
import { supabase } from "../supabaseClient";
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
  payment_status: "unpaid",
  notes: "",
};

const PAYMENT_STATUS = { unpaid: "غير مدفوع", partially_paid: "مدفوع جزئيًا", paid: "مدفوع" };
const REVIEW_STATUS = { draft: "بانتظار المراجعة", rejected: "مرفوض", approved: "معتمد" };

function friendlyError(error) {
  const text = String(error?.message || error || "");
  if (text.includes("Rejection reason")) return "سبب الرفض مطلوب.";
  if (text.includes("must be approved before payment")) return "لا يمكن الدفع قبل اعتماد الوردية.";
  if (text.includes("already paid")) return "تم دفع هذه الوردية بالفعل.";
  if (text.includes("cannot be reviewed again")) return "لا يمكن إعادة مراجعة وردية مدفوعة.";
  if (text.includes("cannot be deleted")) return "لا يمكن حذف وردية تمت مراجعتها أو دفعها أو ربطها بتكلفة مشروع.";
  if (text.includes("permission required")) return "ليس لديك الصلاحية المطلوبة لتنفيذ الإجراء.";
  return text || "تعذر تنفيذ الإجراء.";
}

function Info({ label, value }) {
  return <div><small>{label}</small><strong className="table-sub">{value}</strong></div>;
}

export function DailyLaborForm({ projects, profile, canSeeMoney, onSaved, onCancel }) {
  const [form, setForm] = useState(emptyShift);
  const [error, setError] = useState("");
  const calculation = calculateDailyLabor(form);

  async function submit(event) {
    event.preventDefault();
    setError("");
    const payload = {
      ...form,
      project_id: form.project_id || null,
      break_minutes: number(form.break_minutes),
      hourly_rate: canSeeMoney ? number(form.hourly_rate) : 0,
      overtime_hours: number(form.overtime_hours),
      overtime_rate: canSeeMoney ? number(form.overtime_rate) : 0,
      total_hours: calculation.totalHours,
      total_amount: calculation.totalAmount,
      review_status: "draft",
      created_by: profile.id,
    };
    const mutationResult = await supabase.from("daily_labor").insert(payload);
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
      </PermissionGuard>
      <Field label="ساعات إضافية"><Input type="number" min="0" step=".25" value={form.overtime_hours} onChange={(e) => setForm({ ...form, overtime_hours: e.target.value })}/></Field>
      <Field label="ملاحظات" wide><TextArea value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })}/></Field>
    </div>
    <div className="labor-calculation"><span><Clock3 size={15}/> إجمالي الساعات <b>{calculation.totalHours}</b></span>{canSeeMoney && <span>القيمة المستحقة <b>{money(calculation.totalAmount)}</b></span>}</div>
    <ErrorState error={error}/>
    <div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={onCancel}>إلغاء</Button><Button>حفظ الوردية</Button></div>
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
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [project, setProject] = useState("");
  const [group, setGroup] = useState("none");
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const [busy, setBusy] = useState(false);
  const canSeeMoney = profile.role !== "production";
  const canReview = isAdministrativeRole(profile.role) || permissions.daily_labor_edit;

  const rows = useMemo(() => data.dailyLabor
    .filter((row) => (!from || row.work_date >= from) && (!to || row.work_date <= to) && (!project || row.project_id === project))
    .sort((a, b) => b.work_date.localeCompare(a.work_date)), [data.dailyLabor, from, to, project]);

  const summary = useMemo(() => rows.reduce((acc, row) => ({
    hours: acc.hours + number(row.total_hours),
    total: acc.total + number(row.total_amount),
    paid: acc.paid + number(row.paid_amount),
    unpaid: acc.unpaid + Math.max(0, number(row.total_amount) - number(row.paid_amount)),
  }), { hours: 0, total: 0, paid: 0, unpaid: 0 }), [rows]);

  const grouped = useMemo(() => group === "none" ? [["كل الورديات", rows]] : Object.entries(rows.reduce((acc, row) => {
    const key = group === "worker" ? row.worker_name : (data.projects.find((item) => item.id === row.project_id)?.project_name || "بدون مشروع");
    (acc[key] ??= []).push(row);
    return acc;
  }, {})), [rows, group, data.projects]);

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
      {canSeeMoney && <><StatCard label="إجمالي تكلفة العمالة" value={money(summary.total)}/><StatCard label="المدفوع" value={money(summary.paid)} tone="positive"/><StatCard label="غير المدفوع" value={money(summary.unpaid)} tone="negative"/></>}
      <StatCard label="عدد الورديات" value={rows.length}/>
    </div>
    <Panel>
      <div className="v22-filters">
        <Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} aria-label="من"/>
        <Input type="date" value={to} onChange={(e) => setTo(e.target.value)} aria-label="إلى"/>
        <Select value={project} onChange={(e) => setProject(e.target.value)}><option value="">كل المشاريع</option>{data.projects.map((item) => <option key={item.id} value={item.id}>{item.project_name}</option>)}</Select>
        <Select value={group} onChange={(e) => setGroup(e.target.value)}><option value="none">بدون تجميع</option><option value="worker">تجميع حسب العامل</option><option value="project">تجميع حسب المشروع</option></Select>
      </div>
      {rows.length ? grouped.map(([label, items]) => <div className="labor-group" key={label}>
        <h3>{label}<span>{items.length} وردية</span></h3>
        <DataTable headers={canSeeMoney ? ["العامل", "المشروع", "التاريخ", "الساعات", "الإجمالي", "المراجعة", "الدفع", "إجراءات"] : ["العامل", "المشروع", "التاريخ", "الساعات", "المراجعة", "إجراءات"]}>
          {items.map((row) => <tr key={row.id}>
            <td><strong>{row.worker_name}</strong><br/><small>{row.trade || "—"}</small></td>
            <td>{data.projects.find((item) => item.id === row.project_id)?.project_name || "—"}</td>
            <td>{row.work_date}<br/><small>{row.start_time?.slice(0, 5)} — {row.end_time?.slice(0, 5)}</small></td>
            <td>{row.total_hours}</td>
            {canSeeMoney && <td><strong>{money(row.total_amount)}</strong></td>}
            <td><span className={`payroll-status ${row.review_status || "draft"}`}>{REVIEW_STATUS[row.review_status || "draft"]}</span></td>
            {canSeeMoney && <td><span className={`payroll-status ${row.payment_status}`}>{PAYMENT_STATUS[row.payment_status]}</span></td>}
            <td><div className="v22-actions">
              <Button variant="ghost" onClick={() => setSelected(row)}><Eye size={14}/> فتح التفاصيل</Button>
              {permissions.daily_labor_delete && (row.review_status || "draft") === "draft" && row.payment_status !== "paid" && !row.actual_cost_entry_id && <button className="v22-icon-button danger" onClick={() => remove(row)}><Trash2 size={15}/></button>}
            </div></td>
          </tr>)}
        </DataTable>
      </div>) : <EmptyState title="لا توجد ورديات مطابقة"/>}
    </Panel>

    {showForm && <div className="v22-modal-backdrop"><div className="v22-modal"><h3>تسجيل وردية يومية</h3><DailyLaborForm projects={data.projects} profile={profile} canSeeMoney={canSeeMoney} onCancel={() => setShowForm(false)} onSaved={async () => { const refetchResult = await refresh("dailyLabor"); if (!refetchResult?.error) { setShowForm(false); setSuccess("تم حفظ الوردية بنجاح"); } return refetchResult; }}/></div></div>}

    {selected && <div className="v22-modal-backdrop"><div className="v22-modal">
      <h3>تفاصيل وردية العمالة الخارجية</h3>
      <div className="v22-form-grid">
        <Info label="العامل" value={selected.worker_name}/><Info label="الهاتف" value={selected.phone || "—"}/><Info label="الحرفة" value={selected.trade || "—"}/><Info label="المشروع" value={data.projects.find((item) => item.id === selected.project_id)?.project_name || "بدون مشروع"}/>
        <Info label="تاريخ العمل" value={selected.work_date}/><Info label="بداية الوردية" value={selected.start_time?.slice(0, 5)}/><Info label="نهاية الوردية" value={selected.end_time?.slice(0, 5)}/><Info label="الراحة" value={`${number(selected.break_minutes)} دقيقة`}/>
        <Info label="الساعات الفعلية" value={`${number(selected.total_hours).toFixed(2)} ساعة`}/><Info label="الساعات الإضافية" value={`${number(selected.overtime_hours).toFixed(2)} ساعة`}/>{canSeeMoney && <><Info label="سعر الساعة" value={money(selected.hourly_rate)}/><Info label="سعر الإضافي" value={money(selected.overtime_rate)}/><Info label="الإجمالي المحتسب" value={money(selected.total_amount)}/><Info label="المدفوع" value={money(selected.paid_amount)}/></>}
        <Info label="حالة المراجعة" value={REVIEW_STATUS[selected.review_status || "draft"]}/><Info label="حالة الدفع" value={PAYMENT_STATUS[selected.payment_status]}/>
        {selected.rejection_reason && <Info label="سبب الرفض" value={selected.rejection_reason}/>} {selected.payment_reference && <Info label="مرجع الدفع" value={selected.payment_reference}/>} {selected.payment_notes && <Info label="ملاحظات الدفع" value={selected.payment_notes}/>} {selected.notes && <Info label="ملاحظات الوردية" value={selected.notes}/>} 
      </div>
      <div className="v22-alert info">طريقة الحساب: الساعات الفعلية × سعر الساعة + الساعات الإضافية × سعر الإضافي. راجع التوقيت والراحة والأسعار قبل الاعتماد.</div>
      <div className="v22-actions modal-actions">
        {canReview && selected.payment_status !== "paid" && <><Button variant="danger" onClick={() => { setReviewAction(selected); setReviewReason(""); setSelected(null); }}><XCircle size={14}/> رفض</Button><Button onClick={() => { setReviewAction(selected); setReviewReason(""); setSelected(null); }}><BadgeCheck size={14}/> اعتماد</Button></>}
        {canSeeMoney && permissions.daily_labor_pay && selected.review_status === "approved" && selected.payment_status !== "paid" && <Button onClick={() => { setPaymentAction(selected); setSelected(null); }}><Banknote size={14}/> تسجيل الدفع</Button>}
        <Button variant="ghost" onClick={() => setSelected(null)}>إغلاق</Button>
      </div>
    </div></div>}

    {reviewAction && <div className="v22-modal-backdrop"><div className="v22-modal">
      <h3>قرار مراجعة الوردية</h3>
      <p>اعتماد الوردية يسمح للحسابات بتسجيل الدفع. عند الرفض يجب كتابة السبب.</p>
      <Field label="سبب الرفض"><TextArea value={reviewReason} onChange={(e) => setReviewReason(e.target.value)} placeholder="اكتب السبب عند الرفض..."/></Field>
      <div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={() => setReviewAction(null)}>رجوع</Button><Button variant="danger" disabled={busy} onClick={() => reviewShift(false)}><XCircle size={14}/> رفض</Button><Button disabled={busy} onClick={() => reviewShift(true)}><BadgeCheck size={14}/> اعتماد</Button></div>
    </div></div>}

    {paymentAction && <div className="v22-modal-backdrop"><form className="v22-modal" onSubmit={payShift}>
      <h3>تسجيل دفع مستحق العامل</h3>
      <p>سيتم تسجيل دفع {money(paymentAction.total_amount)} للعامل {paymentAction.worker_name} بعد اعتماده.</p>
      <Field label="مرجع الدفع"><Input value={paymentReference} onChange={(e) => setPaymentReference(e.target.value)} placeholder="رقم التحويل أو السند..."/></Field>
      <Field label="ملاحظات الدفع"><TextArea value={paymentNotes} onChange={(e) => setPaymentNotes(e.target.value)} placeholder="أي تفاصيل تساعد المراجعة لاحقًا..."/></Field>
      <div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={() => setPaymentAction(null)}>رجوع</Button><Button disabled={busy}><Banknote size={14}/> تأكيد الدفع</Button></div>
    </form></div>}

    <Toast message={success} onDismiss={() => setSuccess("")}/>
  </div>;
}
