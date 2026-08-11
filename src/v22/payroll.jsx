import React, { useMemo, useState } from "react";
import { isAdministrativeRole } from "../identity";
import { Eye, PauseCircle, Pencil, PlayCircle, Trash2, UserPlus } from "lucide-react";
import { supabase } from "../supabaseClient";
import { ArchiveSection, DependencySummary, KpiCard, KpiGrid, SearchFilterBar } from "../ui";
import { Button, DataTable, ErrorState, Field, Input, money, number, PageTitle, Panel, TextArea, Toast } from "./shared";
import { runCriticalMutation } from "./mutations";

const EMPLOYEE_STATUS = { active: "نشط", suspended: "موقوف", resigned: "مستقيل", terminated: "منتهي الخدمة" };
const emptyEmployee = { full_name: "", phone: "", job_title: "", department: "", department_id: "", base_salary: 0, housing_allowance: 0, transport_allowance: 0, other_allowance: 0, hire_date: "", status: "active", command_id: "" };
const DEPENDENCY_LABELS = {
  payroll: "مسيرات رواتب",
  login_accounts: "حسابات دخول",
  asset_assignments: "عهد وأصول",
  work_schedules: "جداول عمل",
  holiday_scopes: "عطلات مرتبطة",
  project_memberships: "عضويات مشاريع",
  project_milestones: "مراحل مشاريع",
  production_operations: "عمليات إنتاج",
};
function normalizePhone(value = "") { let phone = String(value).trim().replace(/[^0-9+]/g, ""); if (phone.startsWith("00")) phone = `+${phone.slice(2)}`; return /^\+[1-9][0-9]{7,14}$/.test(phone) ? phone : ""; }
function employeePayload(form) { return { full_name: form.full_name, phone: normalizePhone(form.phone), job_title: form.job_title, department: form.department, department_id: form.department_id || "", base_salary: number(form.base_salary), housing_allowance: number(form.housing_allowance), transport_allowance: number(form.transport_allowance), other_allowance: number(form.other_allowance), hire_date: form.hire_date || "" }; }
function friendlyEmployeeError(error) {
  const text = String(error?.message || error || "");
  const normalized = text.toLowerCase();
  if (normalized.includes("duplicate key") || normalized.includes("employees_phone_normalized_unique")) return "رقم واتساب مستخدم بالفعل لموظف آخر.";
  if (normalized.includes("foreign key") || error?.code === "23503") return "لا يمكن حذف الموظف لأن له سجلًا تاريخيًا مرتبطًا. افتح ملف الموظف لمراجعة الارتباطات ثم استخدم الأرشفة.";
  return text || "تعذر تنفيذ الإجراء.";
}
function dependencyItems(summary) {
  return Object.entries(summary?.dependencies || {})
    .filter(([, count]) => Number(count) > 0)
    .map(([key, count]) => {
      const records = summary?.dependency_records?.[key] || [];
      return {
        id: key,
        label: DEPENDENCY_LABELS[key] || key,
        count,
        description: records.map((record) => record.label || record.reference || record.id).filter(Boolean).join(" • "),
      };
    });
}

export function EmployeesTab({ data, profile, refresh }) {
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState(emptyEmployee);
  const [selected, setSelected] = useState(null);
  const [summary, setSummary] = useState(null);
  const [editForm, setEditForm] = useState(null);
  const [statusAction, setStatusAction] = useState(null);
  const [deleteAction, setDeleteAction] = useState(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const [search, setSearch] = useState("");
  const canManage = isAdministrativeRole(profile.role);
  const employees = useMemo(() => data.employees.filter((employee) => {
    const query = search.trim().toLowerCase();
    return !query
      || employee.full_name.toLowerCase().includes(query)
      || (employee.department || "").toLowerCase().includes(query)
      || (employee.job_title || "").toLowerCase().includes(query)
      || (employee.phone || "").includes(query);
  }), [data.employees, search]);
  const activeEmployees = employees.filter((employee) => employee.status === "active");
  const archivedEmployees = employees.filter((employee) => employee.status !== "active");
  const totalActive = data.employees.filter((employee) => employee.status === "active").length;
  const totalArchived = data.employees.length - totalActive;
  const departmentCount = new Set(data.employees.map((employee) => employee.department).filter(Boolean)).size;

  async function loadSummary(employee) {
    setSelected(employee); setSummary(null); setError("");
    const result = await supabase.rpc("employee_dependency_summary", { target_employee_id: employee.id });
    if (result.error) setError(friendlyEmployeeError(result.error)); else setSummary(result.data);
  }
  async function submit(e) {
    e.preventDefault(); setError(""); setSuccess("");
    const phone = normalizePhone(form.phone);
    if (!phone) return setError("اكتب رقم واتساب الموظف بصيغة دولية، مثال: +9665XXXXXXXX أو +201XXXXXXXXX");
    setBusy(true);
    const commandId = form.command_id || globalThis.crypto.randomUUID();
    if (!form.command_id) setForm((current) => ({ ...current, command_id: commandId }));
    const payload = { ...form, phone, base_salary: number(form.base_salary), housing_allowance: number(form.housing_allowance), transport_allowance: number(form.transport_allowance), other_allowance: number(form.other_allowance), hire_date: form.hire_date || null, department_id: form.department_id || null };
    delete payload.command_id;
    const result = await runCriticalMutation({ scope: "employees:create", mutate: () => supabase.rpc("create_employee_record", { payload, command_id: commandId }), verify: async () => {
      const verification = await supabase.from("employees").select("id,status").eq("command_id", commandId).single();
      return verification.error ? verification : verification.data?.status === "active";
    }, refetch: () => refresh("employees") });
    setBusy(false);
    if (result.error) return setError(friendlyEmployeeError(result.error));
    setShowForm(false); setForm(emptyEmployee); setSuccess("تمت إضافة الموظف ورقم واتساب بنجاح");
  }
  async function saveEdit(e) {
    e.preventDefault(); setError(""); setBusy(true);
    const payload = employeePayload(editForm);
    if (!payload.phone) { setBusy(false); return setError("رقم واتساب مطلوب بصيغة دولية صحيحة."); }
    const result = await supabase.rpc("update_employee_record", { target_employee_id: editForm.id, payload });
    if (!result.error && result.data?.ok !== false) await refresh("employees");
    setBusy(false);
    if (result.error || result.data?.ok === false) return setError(friendlyEmployeeError(result.error || result.data?.error));
    setEditForm(null); setSelected(result.data.employee); setSuccess("تم تحديث بيانات الموظف وتسجيل التعديل.");
  }
  async function changeStatus(e) {
    e.preventDefault(); setError("");
    if (!reason.trim()) return setError("سبب تغيير الحالة مطلوب.");
    setBusy(true);
    const result = await supabase.rpc("set_employee_status", { target_employee_id: statusAction.employee.id, target_status: statusAction.status, reason: reason.trim() });
    if (!result.error && result.data?.ok !== false) await refresh("employees");
    setBusy(false);
    if (result.error || result.data?.ok === false) return setError(friendlyEmployeeError(result.error || result.data?.error));
    setSelected(result.data.employee); setStatusAction(null); setReason("");
    setSuccess(result.data.linked_login_accounts ? "تم تغيير حالة الموظف فقط. حساب الدخول المرتبط لم يتغير." : "تم تغيير حالة الموظف بنجاح.");
  }
  async function deleteEmployee(e) {
    e.preventDefault(); setError("");
    if (!reason.trim()) return setError("سبب الحذف مطلوب.");
    setBusy(true);
    const result = await supabase.rpc("delete_employee_if_unused", { target_employee_id: deleteAction.id, reason: reason.trim() });
    if (!result.error && result.data?.ok) await refresh("employees");
    setBusy(false);
    if (result.error || result.data?.ok === false) {
      if (result.data?.summary) {
        setSelected(deleteAction);
        setSummary(result.data.summary);
        setDeleteAction(null);
      }
      return setError(friendlyEmployeeError(result.error || result.data?.error));
    }
    setDeleteAction(null); setSelected(null); setSummary(null); setReason(""); setSuccess("تم حذف سجل الموظف التجريبي نهائيًا.");
  }

  const employeeRows = (rows) => rows.map((employee) => <tr key={employee.id}><td><strong>{employee.full_name}</strong><br/><small>{employee.phone || "رقم واتساب غير مسجل"}</small></td><td>{employee.job_title || "—"}</td><td>{employee.department || "—"}</td><td>{money(employee.base_salary)}</td><td>{money(number(employee.housing_allowance) + number(employee.transport_allowance) + number(employee.other_allowance))}</td><td><span className={`payroll-status ${employee.status}`}>{EMPLOYEE_STATUS[employee.status]}</span></td><td><div className="v22-actions"><Button variant="ghost" onClick={() => loadSummary(employee)}><Eye size={14}/> فتح</Button>{canManage && <Button variant="ghost" onClick={() => setEditForm({ ...employee, hire_date: employee.hire_date || "", department_id: employee.department_id || "" })}><Pencil size={14}/> تعديل</Button>}{canManage && employee.status === "active" && <Button variant="ghost" onClick={() => { setStatusAction({ employee, status: "suspended" }); setReason(""); }}><PauseCircle size={14}/> أرشفة</Button>}{canManage && employee.status !== "active" && <Button variant="ghost" onClick={() => { setStatusAction({ employee, status: "active" }); setReason(""); }}><PlayCircle size={14}/> استعادة</Button>}</div></td></tr>);
  const employeeTable = (rows, emptyTitle) => rows.length ? <DataTable headers={["الموظف", "المسمى", "القسم", "الراتب الأساسي", "البدلات", "الحالة", "الإجراءات"]}>{employeeRows(rows)}</DataTable> : <EmptyState title={emptyTitle}/>;

  return <div><PageTitle eyebrow="الموارد البشرية" title="الموظفون" description="إضافة وتعديل وأرشفة واستعادة الموظفين مع حماية السجل التاريخي وإظهار كل الارتباطات." actions={canManage && <Button onClick={() => setShowForm(true)}><UserPlus size={16}/> موظف جديد</Button>} /><ErrorState error={error}/>
    <KpiGrid label="ملخص الموظفين"><KpiCard label="الموظفون النشطون" value={totalActive} tone="success"/><KpiCard label="الموظفون المؤرشفون" value={totalArchived} tone={totalArchived ? "warning" : "neutral"}/><KpiCard label="إجمالي الموظفين" value={data.employees.length}/><KpiCard label="الأقسام المسجلة" value={departmentCount}/></KpiGrid>
    <SearchFilterBar value={search} onChange={(event) => setSearch(event.target.value)} searchLabel="البحث في الموظفين" placeholder="ابحث بالاسم أو المسمى أو القسم أو رقم واتساب..."/>
    <Panel><h3>الموظفون النشطون</h3>{employeeTable(activeEmployees, search ? "لا يوجد موظفون نشطون مطابقون" : "لا يوجد موظفون نشطون")}</Panel>
    <ArchiveSection title="الموظفون المؤرشفون" count={archivedEmployees.length} helpText="السجلات الموقوفة أو المستقيلة أو منتهية الخدمة محفوظة للتاريخ ويمكن استعادتها عند الحاجة.">{employeeTable(archivedEmployees, search ? "لا توجد سجلات مؤرشفة مطابقة" : "لا توجد سجلات مؤرشفة")}</ArchiveSection>

    {showForm && <EmployeeForm title="إضافة موظف" form={form} setForm={setForm} data={data} busy={busy} onSubmit={submit} onClose={() => setShowForm(false)} submitLabel="حفظ"/>}
    {editForm && <EmployeeForm title={`تعديل ${editForm.full_name}`} form={editForm} setForm={setEditForm} data={data} busy={busy} onSubmit={saveEdit} onClose={() => setEditForm(null)} submitLabel="حفظ التعديل"/>}
    {selected && <div className="v22-modal-backdrop"><div className="v22-modal"><h3>ملف الموظف</h3><div className="v22-form-grid"><Info label="الاسم" value={selected.full_name}/><Info label="رقم واتساب" value={selected.phone || "غير مسجل"}/><Info label="المسمى الوظيفي" value={selected.job_title || "—"}/><Info label="القسم" value={selected.department || "—"}/><Info label="الحالة" value={EMPLOYEE_STATUS[selected.status]}/><Info label="تاريخ التعيين" value={selected.hire_date || "—"}/><Info label="الراتب الأساسي" value={money(selected.base_salary)}/><Info label="إجمالي البدلات" value={money(number(selected.housing_allowance) + number(selected.transport_allowance) + number(selected.other_allowance))}/>{selected.status_reason && <Info label="آخر سبب لتغيير الحالة" value={selected.status_reason}/>}</div>{summary ? <DependencySummary title="الارتباطات التي تحفظ تاريخ الموظف" items={dependencyItems(summary)} emptyText="لا توجد معاملات مرتبطة؛ يمكن حذف هذا السجل التجريبي نهائيًا."/> : <p>جارِ فحص الارتباطات...</p>}<div className="v22-actions modal-actions">{canManage && summary?.can_delete && <Button variant="danger" onClick={() => { setDeleteAction(selected); setSelected(null); setReason(""); }}><Trash2 size={14}/> حذف نهائي</Button>}<Button onClick={() => setSelected(null)}>إغلاق</Button></div></div></div>}
    {statusAction && <ReasonModal title={statusAction.status === "active" ? "استعادة الموظف" : "أرشفة الموظف"} description={statusAction.status === "active" ? "سيعود الموظف للظهور ضمن الموظفين النشطين والمتاحين للعمليات الجديدة. حساب الدخول لا يتغير تلقائيًا." : "سيُنقل الموظف إلى الأرشيف ويُمنع إسناد عمليات جديدة له، مع بقاء كل الرواتب والعهد والمشاريع محفوظة. حساب الدخول المرتبط لن يتغير تلقائيًا."} reason={reason} setReason={setReason} busy={busy} onSubmit={changeStatus} onClose={() => setStatusAction(null)} submitLabel={statusAction.status === "active" ? "تأكيد الاستعادة" : "تأكيد الأرشفة"}/>}
    {deleteAction && <ReasonModal title="حذف الموظف نهائيًا" description="الحذف متاح فقط إذا لم يكن للموظف أي حساب أو راتب أو عهدة أو عملية مرتبطة. سيتم رفض الطلب تلقائيًا عند وجود أي ارتباط." reason={reason} setReason={setReason} busy={busy} onSubmit={deleteEmployee} onClose={() => setDeleteAction(null)} submitLabel="حذف نهائي" danger/>}
    <Toast message={success} onDismiss={() => setSuccess("")}/>
  </div>;
}

function EmployeeForm({ title, form, setForm, data, busy, onSubmit, onClose, submitLabel }) { return <div className="v22-modal-backdrop"><form className="v22-modal" onSubmit={onSubmit}><h3>{title}</h3><div className="v22-form-grid"><Field label="الاسم الكامل"><Input required value={form.full_name} onChange={(e) => setForm({ ...form, full_name: e.target.value })}/></Field><Field label="رقم واتساب (إجباري)"><Input required type="tel" dir="ltr" placeholder="+9665XXXXXXXX" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })}/><small>اكتب مفتاح الدولة؛ سيُستخدم الرقم لإرسال رابط العهدة.</small></Field><Field label="المسمى الوظيفي"><Input value={form.job_title || ""} onChange={(e) => setForm({ ...form, job_title: e.target.value })}/></Field><Field label="القسم"><Input value={form.department || ""} onChange={(e) => setForm({ ...form, department: e.target.value })}/></Field><Field label="الراتب الأساسي"><Input type="number" min="0" value={form.base_salary} onChange={(e) => setForm({ ...form, base_salary: e.target.value })}/></Field><Field label="بدل السكن"><Input type="number" min="0" value={form.housing_allowance} onChange={(e) => setForm({ ...form, housing_allowance: e.target.value })}/></Field><Field label="بدل النقل"><Input type="number" min="0" value={form.transport_allowance} onChange={(e) => setForm({ ...form, transport_allowance: e.target.value })}/></Field><Field label="بدلات أخرى"><Input type="number" min="0" value={form.other_allowance} onChange={(e) => setForm({ ...form, other_allowance: e.target.value })}/></Field><Field label="تاريخ التعيين"><Input type="date" value={form.hire_date || ""} onChange={(e) => setForm({ ...form, hire_date: e.target.value })}/></Field></div><div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={onClose}>إلغاء</Button><Button disabled={busy}>{busy ? "جارِ الحفظ..." : submitLabel}</Button></div></form></div>; }
function Info({ label, value }) { return <div><small>{label}</small><strong className="table-sub">{value}</strong></div>; }
function ReasonModal({ title, description, reason, setReason, busy, onSubmit, onClose, submitLabel, danger }) { return <div className="v22-modal-backdrop"><form className="v22-modal" onSubmit={onSubmit}><h3>{title}</h3><p>{description}</p><Field label="السبب"><TextArea required value={reason} onChange={(e) => setReason(e.target.value)} placeholder="اكتب سبب الإجراء بوضوح..."/></Field><div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={onClose}>رجوع</Button><Button variant={danger ? "danger" : "primary"} disabled={busy}>{busy ? "جارِ التنفيذ..." : submitLabel}</Button></div></form></div>; }
