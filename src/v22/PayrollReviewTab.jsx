import React, { useMemo, useState } from "react";
import { BadgeCheck, Banknote, Eye, Pencil, Plus, Trash2 } from "lucide-react";
import { isAdministrativeRole } from "../identity";
import { supabase } from "../supabaseClient";
import { ArchiveSection, DetailsDrawer, HelpText, KpiCard, KpiGrid } from "../ui/foundation";
import { Button, ConfirmDialog, DataTable, EmptyState, ErrorState, Field, Input, money, number, PageTitle, Panel, PermissionGuard, Select, TextArea, Toast } from "./shared";
import { calculateNetSalary } from "./calculations";
import { syncMutation } from "./mutations";

const STATUS = { draft: "مسودة", rejected: "مرفوض", approved: "معتمد", paid: "مدفوع" };
const initial = {
  employee_id: "", payroll_month: new Date().toISOString().slice(0, 7),
  overtime_hours: 0, overtime_rate: 0, deductions: 0, deduction_reason: "",
  bonuses: 0, bonus_reason: "", advances: 0, advance_reason: "", notes: "",
};
const n = number;

function friendlyError(error) {
  const text = String(error?.message || error || "");
  if (text.includes("Deduction reason")) return "اكتب سبب الخصم.";
  if (text.includes("Advance reason")) return "اكتب تفاصيل السلفة أو القسط.";
  if (text.includes("Bonus reason")) return "اكتب سبب المكافأة.";
  if (text.includes("Rejection reason")) return "سبب الرفض مطلوب.";
  if (text.includes("Attendance days")) return "أدخل أيام الحضور قبل الحفظ.";
  if (text.includes("Absence days")) return "أدخل أيام الغياب قبل الحفظ.";
  if (text.includes("Attendance source")) return "اكتب مصدر بيانات الحضور والغياب.";
  if (text.includes("Attendance and absence")) return "مجموع الحضور والغياب يجب أن يساوي أيام العمل المجدولة.";
  if (text.includes("Approved work calendar")) return "لا يوجد تقويم عمل معتمد يغطي هذا الموظف والشهر.";
  if (text.includes("review details are incomplete")) return "بيانات مراجعة الراتب غير مكتملة. راجع التنبيهات داخل التفاصيل.";
  if (text.includes("Only draft or rejected")) return "لا يمكن تعديل راتب معتمد أو مدفوع.";
  if (text.includes("Only approved payroll")) return "لا يمكن تسجيل الصرف إلا لمسير معتمد.";
  if (text.includes("permission")) return "ليست لديك صلاحية تنفيذ هذا الإجراء.";
  return "تعذر تنفيذ العملية. راجع البيانات وحاول مرة أخرى.";
}

function validate(values, includeAttendance = false) {
  if (n(values.deductions) > 0 && !values.deduction_reason?.trim()) return "اكتب سبب الخصم.";
  if (n(values.advances) > 0 && !values.advance_reason?.trim()) return "اكتب تفاصيل السلفة أو القسط.";
  if (n(values.bonuses) > 0 && !values.bonus_reason?.trim()) return "اكتب سبب المكافأة.";
  if (includeAttendance && (values.attended_days === null || values.attended_days === undefined || values.attended_days === "")) return "أدخل أيام الحضور.";
  if (includeAttendance && (values.absence_days === null || values.absence_days === undefined || values.absence_days === "")) return "أدخل أيام الغياب.";
  if (includeAttendance && !values.attendance_source?.trim()) return "اكتب مصدر بيانات الحضور والغياب.";
  return "";
}

function Info({ label, value, source }) {
  return <div className="payroll-review-value"><small>{label}</small><strong className="table-sub">{value}</strong>{source && <span>المصدر: {source}</span>}</div>;
}

function PayrollTable({ rows, data, onOpen, onRemove, profile }) {
  if (!rows.length) return <EmptyState title="لا توجد مسيرات في هذا القسم"/>;
  return <DataTable headers={["الموظف", "الشهر", "الخصومات", "السلف", "الصافي", "الحالة", "الإجراء"]}>
    {rows.map((row) => <tr key={row.id}>
      <td>{data.employees.find((employee) => employee.id === row.employee_id)?.full_name || "موظف غير موجود"}</td>
      <td>{row.payroll_month?.slice(0, 7)}</td>
      <td>{money(row.deductions)}</td>
      <td>{money(row.advances)}</td>
      <td><strong>{money(row.net_salary)}</strong></td>
      <td><span className={`payroll-status ${row.status}`}>{STATUS[row.status]}</span></td>
      <td><div className="v22-actions">
        <Button variant="ghost" onClick={() => onOpen(row)}><Eye size={14}/> فتح التفاصيل</Button>
        {isAdministrativeRole(profile.role) && ["draft", "rejected"].includes(row.status) && <button type="button" aria-label="حذف المسودة" className="v22-icon-button danger" onClick={() => onRemove(row)}><Trash2 size={15}/></button>}
      </div></td>
    </tr>)}
  </DataTable>;
}

export function PayrollReviewTab({ data, profile, permissions, refresh }) {
  const [form, setForm] = useState(initial);
  const [show, setShow] = useState(false);
  const [selected, setSelected] = useState(null);
  const [snapshot, setSnapshot] = useState(null);
  const [snapshotLoading, setSnapshotLoading] = useState(false);
  const [edit, setEdit] = useState(null);
  const [reject, setReject] = useState(null);
  const [reason, setReason] = useState("");
  const [pendingPaid, setPendingPaid] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const [month, setMonth] = useState(new Date().toISOString().slice(0, 7));
  const [status, setStatus] = useState("");

  const rows = useMemo(() => data.payroll.filter((row) =>
    (!month || row.payroll_month?.slice(0, 7) === month) && (!status || row.status === status)
  ), [data.payroll, month, status]);
  const activeRows = rows.filter((row) => ["draft", "rejected"].includes(row.status));
  const archivedRows = rows.filter((row) => ["approved", "paid"].includes(row.status));
  const employee = data.employees.find((row) => row.id === form.employee_id);
  const preview = employee ? calculateNetSalary({ ...employee, ...form }) : 0;
  const canEdit = permissions.payroll_edit || permissions.payroll_approve || isAdministrativeRole(profile.role);

  async function openDetails(row) {
    setSelected(row);
    setSnapshot(null);
    setSnapshotLoading(true);
    setError("");
    const result = await supabase.rpc("get_payroll_review_snapshot", { target_payroll_id: row.id });
    setSnapshotLoading(false);
    if (result.error || result.data?.ok === false) {
      setError(friendlyError(result.error || result.data?.error));
      return;
    }
    setSelected(result.data.payroll);
    setSnapshot(result.data);
  }

  async function create(event) {
    event.preventDefault();
    setError("");
    const validation = validate(form);
    if (validation) return setError(validation);
    if (!employee) return setError("اختر الموظف.");
    setBusy(true);
    const payload = {
      employee_id: employee.id, payroll_month: `${form.payroll_month}-01`,
      base_salary: n(employee.base_salary), housing_allowance: n(employee.housing_allowance),
      transport_allowance: n(employee.transport_allowance), other_allowance: n(employee.other_allowance),
      overtime_hours: n(form.overtime_hours), overtime_rate: n(form.overtime_rate),
      deductions: n(form.deductions), deduction_reason: form.deduction_reason.trim() || null,
      bonuses: permissions.payroll_bonus_manage ? n(form.bonuses) : 0,
      bonus_reason: permissions.payroll_bonus_manage ? form.bonus_reason.trim() || null : null,
      advances: n(form.advances), advance_reason: form.advance_reason.trim() || null,
      notes: form.notes.trim() || null, created_by: profile.id,
    };
    const mutationResult = await supabase.from("payroll").insert(payload);
    const result = await syncMutation({ scope: "payroll:create", mutationResult, refetch: () => refresh("payroll") });
    setBusy(false);
    if (result.error) return setError(friendlyError(result.error));
    setShow(false);
    setForm(initial);
    setSuccess("تم إنشاء المسودة. افتح التفاصيل وسجل مراجعة الحضور قبل الاعتماد.");
  }

  async function save(event) {
    event.preventDefault();
    setError("");
    const validation = validate(edit, true);
    if (validation) return setError(validation);
    setBusy(true);
    const payload = {
      overtime_hours: n(edit.overtime_hours), overtime_rate: n(edit.overtime_rate),
      deductions: n(edit.deductions), deduction_reason: edit.deduction_reason,
      bonuses: n(edit.bonuses), bonus_reason: edit.bonus_reason,
      advances: n(edit.advances), advance_reason: edit.advance_reason,
      attended_days: edit.attended_days, absence_days: edit.absence_days,
      attendance_source: edit.attendance_source, notes: edit.notes,
    };
    const result = await supabase.rpc("update_payroll_review", { target_payroll_id: edit.id, payload });
    if (!result.error) await refresh("payroll");
    setBusy(false);
    if (result.error || result.data?.ok === false) return setError(friendlyError(result.error || result.data?.error));
    setEdit(null);
    await openDetails(result.data.payroll);
    setSuccess("تم حفظ المراجعة وتحديث أيام العمل من التقويم المعتمد دون تغيير معادلة الراتب.");
  }

  async function decide(row, approve, why = null) {
    setBusy(true);
    setError("");
    const result = await supabase.rpc("review_payroll", { target_payroll_id: row.id, approve, reason: why });
    if (!result.error) await refresh("payroll");
    setBusy(false);
    if (result.error || result.data?.ok === false) {
      setError(friendlyError(result.error || result.data?.error));
      return false;
    }
    setSuccess(approve ? "تم اعتماد الراتب بعد اكتمال المراجعة." : "تم رفض الراتب وإعادته للتصحيح.");
    return true;
  }

  async function paid(row) {
    setBusy(true);
    setError("");
    const result = await supabase.rpc("mark_payroll_paid", { target_payroll_id: row.id });
    if (!result.error) await refresh("payroll");
    setBusy(false);
    if (result.error || result.data?.ok === false) setError(friendlyError(result.error || result.data?.error));
    else setSuccess("تم تسجيل صرف الراتب في المسار المحمي.");
    return result;
  }

  async function remove(row) {
    if (!["draft", "rejected"].includes(row.status)) return setError("لا يمكن حذف راتب معتمد أو مدفوع.");
    if (!window.confirm("حذف مسودة الراتب؟")) return;
    const mutationResult = await supabase.from("payroll").delete().eq("id", row.id);
    const result = await syncMutation({ scope: "payroll:delete", mutationResult, refetch: () => refresh("payroll") });
    if (result.error) setError(friendlyError(result.error));
    else setSuccess("تم حذف المسودة.");
  }

  const totalNet = rows.reduce((sum, row) => sum + n(row.net_salary), 0);
  return <div>
    <PageTitle eyebrow="المحاسبة · مراجعة واعتماد" title="الرواتب" description="ابدأ بالمسيرات النشطة، وافتح تفاصيل الموظف لمراجعة مصدر كل رقم قبل الاعتماد." actions={<PermissionGuard allow={permissions.payroll_create}><Button onClick={() => setShow(true)}><Plus size={16}/> إنشاء راتب</Button></PermissionGuard>}/>
    <ErrorState error={error}/>
    <KpiGrid className="payroll-stats">
      <KpiCard label="تحتاج مراجعة" value={activeRows.length}/>
      <KpiCard label="معتمدة بانتظار الصرف" value={rows.filter((row) => row.status === "approved").length}/>
      <KpiCard label="تم صرفها" value={rows.filter((row) => row.status === "paid").length}/>
      <KpiCard label="إجمالي الصافي" value={money(totalNet)}/>
    </KpiGrid>
    <Panel>
      <div className="v22-filters">
        <Input aria-label="شهر الرواتب" type="month" value={month} onChange={(event) => setMonth(event.target.value)}/>
        <Select aria-label="حالة المسير" value={status} onChange={(event) => setStatus(event.target.value)}>
          <option value="">كل الحالات</option>
          {Object.entries(STATUS).map(([key, label]) => <option key={key} value={key}>{label}</option>)}
        </Select>
      </div>
      <h3>المسيرات النشطة</h3>
      <PayrollTable rows={activeRows} data={data} onOpen={openDetails} onRemove={remove} profile={profile}/>
    </Panel>
    <ArchiveSection title="المسيرات المعتمدة والمدفوعة" count={archivedRows.length} helpText="الأرشيف مطوي افتراضيًا لتبقى المراجعات الحالية في المقدمة.">
      <PayrollTable rows={archivedRows} data={data} onOpen={openDetails} onRemove={remove} profile={profile}/>
    </ArchiveSection>

    {show && <PayrollForm title="إنشاء مسودة راتب" values={form} setValues={setForm} data={data} permissions={permissions} busy={busy} onSubmit={create} onClose={() => setShow(false)} preview={preview} choose/>}
    {edit && <PayrollForm title="مراجعة بيانات الموظف والمسير" values={edit} setValues={setEdit} data={data} permissions={permissions} busy={busy} onSubmit={save} onClose={() => setEdit(null)} preview={n(edit.base_salary) + n(edit.housing_allowance) + n(edit.transport_allowance) + n(edit.other_allowance) + n(edit.overtime_hours) * n(edit.overtime_rate) + n(edit.bonuses) - n(edit.deductions) - n(edit.advances)}/>}
    <PayrollDetails row={selected} snapshot={snapshot} loading={snapshotLoading} permissions={permissions} canEdit={canEdit} busy={busy}
      onEdit={() => { setEdit({ ...selected, attended_days: selected.attended_days ?? "", absence_days: selected.absence_days ?? "", attendance_source: selected.attendance_source || "", deduction_reason: selected.deduction_reason || "", advance_reason: selected.advance_reason || "", bonus_reason: selected.bonus_reason || "", notes: selected.notes || "" }); setSelected(null); setSnapshot(null); }}
      onApprove={async () => { if (await decide(selected, true)) { setSelected(null); setSnapshot(null); } }}
      onReject={() => { setReject(selected); setReason(""); setSelected(null); setSnapshot(null); }}
      onPaid={() => { setPendingPaid(selected); setSelected(null); setSnapshot(null); }}
      onClose={() => { setSelected(null); setSnapshot(null); }}/>

    {reject && <div className="v22-modal-backdrop"><form className="v22-modal" onSubmit={async (event) => { event.preventDefault(); if (!reason.trim()) return setError("سبب الرفض مطلوب."); if (await decide(reject, false, reason.trim())) { setReject(null); setReason(""); } }}>
      <h3>رفض مسودة الراتب</h3>
      <Field label="سبب الرفض"><TextArea required value={reason} onChange={(event) => setReason(event.target.value)} placeholder="ما الذي يجب تصحيحه؟"/></Field>
      <div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={() => setReject(null)}>رجوع</Button><Button variant="danger" disabled={busy}>تأكيد الرفض</Button></div>
    </form></div>}
    <ConfirmDialog open={Boolean(pendingPaid)} title="تأكيد صرف الراتب" description={`سيتم تسجيل راتب ${data.employees.find((row) => row.id === pendingPaid?.employee_id)?.full_name || "الموظف"} بقيمة ${money(pendingPaid?.net_salary)} كمدفوع.`} confirmLabel="نعم، تم الصرف" onCancel={() => setPendingPaid(null)} onConfirm={async () => { const result = await paid(pendingPaid); if (!result.error && result.data?.ok !== false) setPendingPaid(null); }}/>
    <Toast message={success} onDismiss={() => setSuccess("")}/>
  </div>;
}

function PayrollForm({ title, values, setValues, data, permissions, busy, onSubmit, onClose, preview, choose }) {
  return <div className="v22-modal-backdrop"><form className="v22-modal" onSubmit={onSubmit}>
    <h3>{title}</h3>
    {choose && <HelpText title="خطوة أولى">ينشئ النظام مسودة فقط. يجب فتح تفاصيلها لاحقًا وتسجيل الحضور والغياب ومصدرهما قبل الاعتماد.</HelpText>}
    <div className="v22-form-grid">
      {choose && <><Field label="الموظف"><Select required value={values.employee_id} onChange={(event) => setValues({ ...values, employee_id: event.target.value })}><option value="">اختر الموظف</option>{data.employees.filter((row) => row.status === "active").map((row) => <option key={row.id} value={row.id}>{row.full_name}</option>)}</Select></Field><Field label="الشهر"><Input required type="month" value={values.payroll_month} onChange={(event) => setValues({ ...values, payroll_month: event.target.value })}/></Field></>}
      {!choose && <><Field label="أيام الحضور"><Input required type="number" min="0" step=".5" value={values.attended_days} onChange={(event) => setValues({ ...values, attended_days: event.target.value })}/></Field><Field label="أيام الغياب"><Input required type="number" min="0" step=".5" value={values.absence_days} onChange={(event) => setValues({ ...values, absence_days: event.target.value })}/></Field><Field label="مصدر الحضور والغياب" wide><TextArea required value={values.attendance_source} onChange={(event) => setValues({ ...values, attendance_source: event.target.value })} placeholder="مثال: كشف حضور موقع الرياض رقم 24، راجعه مدير الموقع"/></Field></>}
      <Field label="ساعات إضافية"><Input type="number" min="0" step=".25" value={values.overtime_hours} onChange={(event) => setValues({ ...values, overtime_hours: event.target.value })}/></Field>
      <Field label="سعر الساعة الإضافية"><Input type="number" min="0" value={values.overtime_rate} onChange={(event) => setValues({ ...values, overtime_rate: event.target.value })}/></Field>
      <Field label="الخصومات"><Input type="number" min="0" value={values.deductions} onChange={(event) => setValues({ ...values, deductions: event.target.value })}/></Field>
      <Field label="سبب الخصم"><TextArea value={values.deduction_reason || ""} onChange={(event) => setValues({ ...values, deduction_reason: event.target.value })}/></Field>
      <PermissionGuard allow={permissions.payroll_bonus_manage}><Field label="المكافآت"><Input type="number" min="0" value={values.bonuses} onChange={(event) => setValues({ ...values, bonuses: event.target.value })}/></Field></PermissionGuard>
      <PermissionGuard allow={permissions.payroll_bonus_manage}><Field label="سبب المكافأة"><TextArea value={values.bonus_reason || ""} onChange={(event) => setValues({ ...values, bonus_reason: event.target.value })}/></Field></PermissionGuard>
      <Field label="السلفة/القسط"><Input type="number" min="0" value={values.advances} onChange={(event) => setValues({ ...values, advances: event.target.value })}/></Field>
      <Field label="تفاصيل السلفة"><TextArea value={values.advance_reason || ""} onChange={(event) => setValues({ ...values, advance_reason: event.target.value })}/></Field>
      <Field label="ملاحظات" wide><TextArea value={values.notes || ""} onChange={(event) => setValues({ ...values, notes: event.target.value })}/></Field>
    </div>
    <div className="payroll-preview"><span>صافي الراتب المتوقع — المعادلة الحالية</span><strong>{money(preview)}</strong></div>
    <div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={onClose}>إلغاء</Button><Button disabled={busy}>{busy ? "جاري الحفظ..." : "حفظ المراجعة"}</Button></div>
  </form></div>;
}

function PayrollDetails({ row, snapshot, loading, permissions, canEdit, busy, onEdit, onApprove, onReject, onPaid, onClose }) {
  if (!row) return null;
  const sources = snapshot?.sources || {};
  const gross = n(row.base_salary) + n(row.housing_allowance) + n(row.transport_allowance) + n(row.other_allowance) + n(row.overtime_amount) + n(row.bonuses);
  const ready = Boolean(snapshot?.review_ready);
  const blockers = snapshot?.blockers || [];
  const footer = <div className="v22-actions">
    {canEdit && ["draft", "rejected"].includes(row.status) && <Button variant="ghost" onClick={onEdit}><Pencil size={14}/> تعديل المراجعة</Button>}
    <PermissionGuard allow={["draft", "rejected"].includes(row.status) && permissions.payroll_approve}><Button variant="danger" onClick={onReject}>رفض</Button></PermissionGuard>
    <PermissionGuard allow={["draft", "rejected"].includes(row.status) && permissions.payroll_approve}><Button disabled={busy || loading || !ready} onClick={onApprove}><BadgeCheck size={14}/> اعتماد بعد المراجعة</Button></PermissionGuard>
    <PermissionGuard allow={row.status === "approved" && permissions.payroll_mark_paid}><Button onClick={onPaid}><Banknote size={14}/> تسجيل الصرف</Button></PermissionGuard>
  </div>;
  return <DetailsDrawer open title={`تفاصيل راتب ${row.employee_name || "الموظف"}`} description={`${row.payroll_month?.slice(0, 7)} · ${STATUS[row.status]}`} onClose={onClose} footer={footer}>
    {loading && <HelpText title="تحميل المراجعة">جاري التحقق من مصادر الأرقام وجاهزية الاعتماد…</HelpText>}
    {!loading && blockers.length > 0 && <HelpText title="لا يمكن الاعتماد بعد" tone="warning"><ul>{blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul></HelpText>}
    {!loading && ready && <HelpText title="جاهز للاعتماد" tone="success">اكتملت أيام العمل والحضور والأسباب المطلوبة، وسيعيد الخادم التحقق عند الاعتماد.</HelpText>}
    <div className="v22-form-grid">
      <Info label="أيام العمل" value={row.scheduled_work_days ?? "غير مراجع"} source={sources.work_calendar || "تقويم العمل المعتمد"}/>
      <Info label="إجمالي دقائق العمل" value={row.scheduled_minutes ?? "غير مراجع"} source={sources.work_calendar || "تقويم العمل المعتمد"}/>
      <Info label="أيام الحضور" value={row.attended_days ?? "غير مسجل"} source={sources.attendance || "مصدر الحضور المطلوب"}/>
      <Info label="أيام الغياب" value={row.absence_days ?? "غير مسجل"} source={sources.attendance || "مصدر الحضور المطلوب"}/>
      <Info label="الراتب الأساسي" value={money(row.base_salary)} source={sources.salary_snapshot || "نسخة بيانات الموظف"}/>
      <Info label="بدل السكن" value={money(row.housing_allowance)} source={sources.salary_snapshot || "نسخة بيانات الموظف"}/>
      <Info label="بدل النقل" value={money(row.transport_allowance)} source={sources.salary_snapshot || "نسخة بيانات الموظف"}/>
      <Info label="بدلات أخرى" value={money(row.other_allowance)} source={sources.salary_snapshot || "نسخة بيانات الموظف"}/>
      <Info label="العمل الإضافي" value={`${n(row.overtime_hours)} ساعة × ${money(row.overtime_rate)} = ${money(row.overtime_amount)}`} source={sources.review_inputs || "إدخال المراجع"}/>
      <Info label="المكافآت" value={money(row.bonuses)} source={sources.review_inputs || "إدخال المراجع"}/>
      <Info label="إجمالي الراتب" value={money(gross)} source={sources.formula || "المعادلة الحالية"}/>
      <Info label="الخصومات" value={money(row.deductions)} source={sources.review_inputs || "إدخال المراجع"}/>
      <Info label="السلفة/القسط" value={money(row.advances)} source={sources.review_inputs || "إدخال المراجع"}/>
      <Info label="صافي الراتب" value={money(row.net_salary)} source={sources.formula || "المعادلة الحالية"}/>
    </div>
    <Panel><strong>الأسباب والتفاصيل</strong><p>سبب الخصم: {row.deduction_reason || (n(row.deductions) ? "غير مسجل" : "لا يوجد")}</p><p>تفاصيل السلفة: {row.advance_reason || (n(row.advances) ? "غير مسجلة" : "لا يوجد")}</p><p>سبب المكافأة: {row.bonus_reason || (n(row.bonuses) ? "غير مسجل" : "لا يوجد")}</p></Panel>
    {row.rejection_reason && <Panel><strong>سبب الرفض السابق</strong><p>{row.rejection_reason}</p></Panel>}
    {row.notes && <Panel><strong>ملاحظات</strong><p>{row.notes}</p></Panel>}
    <Panel><strong>سجل المراجعة غير القابل للإخفاء</strong><p>إنشاء المسودة: {row.created_at || "غير مسجل"} · بواسطة {row.created_by || "النظام"}</p><p>آخر مراجعة: {row.review_updated_at || "لم تراجع"} · بواسطة {row.review_updated_by || "—"}</p><p>مراجعة الحضور: {row.attendance_reviewed_at || "لم تراجع"} · بواسطة {row.attendance_reviewed_by || "—"}</p><p>الاعتماد: {row.approved_at || "لم يعتمد"} · الصرف: {row.paid_at || "لم يصرف"}</p></Panel>
  </DetailsDrawer>;
}
