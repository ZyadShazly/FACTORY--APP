import React, { useMemo, useState } from "react";
import { isAdministrativeRole } from "../identity";
import { BadgeCheck, Banknote, Eye, PauseCircle, Pencil, PlayCircle, Plus, Trash2, UserPlus } from "lucide-react";
import { supabase } from "../supabaseClient";
import { Button, ConfirmDialog, DataTable, EmptyState, ErrorState, Field, Input, money, number, PageTitle, Panel, PermissionGuard, Select, StatCard, TextArea, Toast } from "./shared";
import { calculateNetSalary } from "./calculations";
import { syncMutation } from "./mutations";

const EMPLOYEE_STATUS = { active: "نشط", suspended: "موقوف", resigned: "مستقيل", terminated: "منتهي الخدمة" };
const PAYROLL_STATUS = { draft: "مسودة", approved: "معتمد", paid: "مدفوع" };
const emptyEmployee = { full_name: "", phone: "", job_title: "", department: "", department_id: "", base_salary: 0, housing_allowance: 0, transport_allowance: 0, other_allowance: 0, hire_date: "", status: "active" };
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
function friendlyEmployeeError(error) { const text = String(error?.message || error || ""); if (text.includes("duplicate key") || text.includes("employees_phone_normalized_unique")) return "رقم واتساب مستخدم بالفعل لموظف آخر."; if (text.includes("foreign key")) return "لا يمكن تنفيذ الإجراء لأن الموظف مرتبط ببيانات أخرى."; return text || "تعذر تنفيذ الإجراء."; }

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
  const employees = data.employees.filter((e) => e.full_name.toLowerCase().includes(search.toLowerCase()) || (e.department || "").toLowerCase().includes(search.toLowerCase()) || (e.phone || "").includes(search));

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
    const payload = { ...form, phone, base_salary: number(form.base_salary), housing_allowance: number(form.housing_allowance), transport_allowance: number(form.transport_allowance), other_allowance: number(form.other_allowance), hire_date: form.hire_date || null, department_id: form.department_id || null, created_by: profile.id };
    const mutationResult = await supabase.from("employees").insert(payload);
    const result = await syncMutation({ scope: "employees:create", mutationResult, refetch: () => refresh("employees") });
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
    if (result.error || result.data?.ok === false) return setError(friendlyEmployeeError(result.error || result.data?.error));
    setDeleteAction(null); setSelected(null); setSummary(null); setReason(""); setSuccess("تم حذف سجل الموظف التجريبي نهائيًا.");
  }

  return <div><PageTitle eyebrow="الموارد البشرية" title="الموظفون" description="فتح وتعديل وإيقاف وإعادة تفعيل الموظفين مع حذف آمن للسجلات التجريبية فقط." actions={canManage && <Button onClick={() => setShowForm(true)}><UserPlus size={16}/> موظف جديد</Button>} /><ErrorState error={error}/>
    <Panel><div className="v22-filters"><Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="ابحث بالاسم أو القسم أو رقم واتساب..."/></div>{employees.length ? <DataTable headers={["الموظف", "المسمى", "القسم", "الراتب الأساسي", "البدلات", "الحالة", "الإجراءات"]}>{employees.map((employee) => <tr key={employee.id}><td><strong>{employee.full_name}</strong><br/><small>{employee.phone || "رقم واتساب غير مسجل"}</small></td><td>{employee.job_title || "—"}</td><td>{employee.department || "—"}</td><td>{money(employee.base_salary)}</td><td>{money(number(employee.housing_allowance) + number(employee.transport_allowance) + number(employee.other_allowance))}</td><td><span className={`payroll-status ${employee.status}`}>{EMPLOYEE_STATUS[employee.status]}</span></td><td><div className="v22-actions"><Button variant="ghost" onClick={() => loadSummary(employee)}><Eye size={14}/> فتح</Button>{canManage && <Button variant="ghost" onClick={() => setEditForm({ ...employee, hire_date: employee.hire_date || "", department_id: employee.department_id || "" })}><Pencil size={14}/> تعديل</Button>}{canManage && employee.status === "active" && <Button variant="ghost" onClick={() => { setStatusAction({ employee, status: "suspended" }); setReason(""); }}><PauseCircle size={14}/> إيقاف</Button>}{canManage && employee.status !== "active" && <Button variant="ghost" onClick={() => { setStatusAction({ employee, status: "active" }); setReason(""); }}><PlayCircle size={14}/> تفعيل</Button>}</div></td></tr>)}</DataTable> : <EmptyState title="لا يوجد موظفون"/>}</Panel>

    {showForm && <EmployeeForm title="إضافة موظف" form={form} setForm={setForm} data={data} busy={busy} onSubmit={submit} onClose={() => setShowForm(false)} submitLabel="حفظ"/>}
    {editForm && <EmployeeForm title={`تعديل ${editForm.full_name}`} form={editForm} setForm={setEditForm} data={data} busy={busy} onSubmit={saveEdit} onClose={() => setEditForm(null)} submitLabel="حفظ التعديل"/>}
    {selected && <div className="v22-modal-backdrop"><div className="v22-modal"><h3>ملف الموظف</h3><div className="v22-form-grid"><Info label="الاسم" value={selected.full_name}/><Info label="رقم واتساب" value={selected.phone || "غير مسجل"}/><Info label="المسمى الوظيفي" value={selected.job_title || "—"}/><Info label="القسم" value={selected.department || "—"}/><Info label="الحالة" value={EMPLOYEE_STATUS[selected.status]}/><Info label="تاريخ التعيين" value={selected.hire_date || "—"}/><Info label="الراتب الأساسي" value={money(selected.base_salary)}/><Info label="إجمالي البدلات" value={money(number(selected.housing_allowance) + number(selected.transport_allowance) + number(selected.other_allowance))}/>{selected.status_reason && <Info label="آخر سبب لتغيير الحالة" value={selected.status_reason}/>}</div><h4>الارتباطات</h4>{summary ? <>{Object.entries(summary.dependencies || {}).filter(([, count]) => Number(count) > 0).map(([key, count]) => <div className="setting-row" key={key}><span>{DEPENDENCY_LABELS[key] || key}</span><b>{count}</b></div>)}{summary.dependency_total === 0 && <EmptyState title="لا توجد معاملات مرتبطة" description="يمكن حذف هذا السجل التجريبي نهائيًا."/>}</> : <p>جارِ فحص الارتباطات...</p>}<div className="v22-actions modal-actions">{canManage && summary?.can_delete && <Button variant="danger" onClick={() => { setDeleteAction(selected); setSelected(null); setReason(""); }}><Trash2 size={14}/> حذف نهائي</Button>}<Button onClick={() => setSelected(null)}>إغلاق</Button></div></div></div>}
    {statusAction && <ReasonModal title={statusAction.status === "active" ? "إعادة تفعيل الموظف" : "إيقاف الموظف"} description={statusAction.status === "active" ? "سيعود الموظف للظهور ضمن الموظفين المتاحين للعمليات الجديدة. حساب الدخول لا يتغير تلقائيًا." : "سيُمنع إسناد عمليات جديدة للموظف. حساب الدخول المرتبط لن يتم إيقافه تلقائيًا."} reason={reason} setReason={setReason} busy={busy} onSubmit={changeStatus} onClose={() => setStatusAction(null)} submitLabel={statusAction.status === "active" ? "إعادة التفعيل" : "تأكيد الإيقاف"}/>} 
    {deleteAction && <ReasonModal title="حذف الموظف نهائيًا" description="الحذف متاح فقط إذا لم يكن للموظف أي حساب أو راتب أو عهدة أو عملية مرتبطة. سيتم رفض الطلب تلقائيًا عند وجود أي ارتباط." reason={reason} setReason={setReason} busy={busy} onSubmit={deleteEmployee} onClose={() => setDeleteAction(null)} submitLabel="حذف نهائي" danger/>}
    <Toast message={success} onDismiss={() => setSuccess("")}/>
  </div>;
}

function EmployeeForm({ title, form, setForm, data, busy, onSubmit, onClose, submitLabel }) { return <div className="v22-modal-backdrop"><form className="v22-modal" onSubmit={onSubmit}><h3>{title}</h3><div className="v22-form-grid"><Field label="الاسم الكامل"><Input required value={form.full_name} onChange={(e) => setForm({ ...form, full_name: e.target.value })}/></Field><Field label="رقم واتساب (إجباري)"><Input required type="tel" dir="ltr" placeholder="+9665XXXXXXXX" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })}/><small>اكتب مفتاح الدولة؛ سيُستخدم الرقم لإرسال رابط العهدة.</small></Field><Field label="المسمى الوظيفي"><Input value={form.job_title || ""} onChange={(e) => setForm({ ...form, job_title: e.target.value })}/></Field><Field label="القسم"><Input value={form.department || ""} onChange={(e) => setForm({ ...form, department: e.target.value })}/></Field><Field label="الراتب الأساسي"><Input type="number" min="0" value={form.base_salary} onChange={(e) => setForm({ ...form, base_salary: e.target.value })}/></Field><Field label="بدل السكن"><Input type="number" min="0" value={form.housing_allowance} onChange={(e) => setForm({ ...form, housing_allowance: e.target.value })}/></Field><Field label="بدل النقل"><Input type="number" min="0" value={form.transport_allowance} onChange={(e) => setForm({ ...form, transport_allowance: e.target.value })}/></Field><Field label="بدلات أخرى"><Input type="number" min="0" value={form.other_allowance} onChange={(e) => setForm({ ...form, other_allowance: e.target.value })}/></Field><Field label="تاريخ التعيين"><Input type="date" value={form.hire_date || ""} onChange={(e) => setForm({ ...form, hire_date: e.target.value })}/></Field></div><div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={onClose}>إلغاء</Button><Button disabled={busy}>{busy ? "جارِ الحفظ..." : submitLabel}</Button></div></form></div>; }
function Info({ label, value }) { return <div><small>{label}</small><strong className="table-sub">{value}</strong></div>; }
function ReasonModal({ title, description, reason, setReason, busy, onSubmit, onClose, submitLabel, danger }) { return <div className="v22-modal-backdrop"><form className="v22-modal" onSubmit={onSubmit}><h3>{title}</h3><p>{description}</p><Field label="السبب"><TextArea required value={reason} onChange={(e) => setReason(e.target.value)} placeholder="اكتب سبب الإجراء بوضوح..."/></Field><div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={onClose}>رجوع</Button><Button variant={danger ? "danger" : "primary"} disabled={busy}>{busy ? "جارِ التنفيذ..." : submitLabel}</Button></div></form></div>; }

const initialPayroll = { employee_id: "", payroll_month: new Date().toISOString().slice(0, 7), overtime_hours: 0, overtime_rate: 0, deductions: 0, bonuses: 0, advances: 0, notes: "" };
export function PayrollTab({ data, profile, permissions, refresh }) {
  const [form, setForm] = useState(initialPayroll); const [showForm, setShowForm] = useState(false); const [error, setError] = useState(""); const [success, setSuccess] = useState(""); const [month, setMonth] = useState(new Date().toISOString().slice(0, 7)); const [status, setStatus] = useState(""); const [pendingPaid, setPendingPaid] = useState(null);
  const rows = useMemo(() => data.payroll.filter((p) => (!month || p.payroll_month?.slice(0, 7) === month) && (!status || p.status === status)), [data.payroll, month, status]);
  const totals = useMemo(() => rows.reduce((a, p) => ({ net: a.net + number(p.net_salary), deductions: a.deductions + number(p.deductions), bonuses: a.bonuses + number(p.bonuses), advances: a.advances + number(p.advances) }), { net: 0, deductions: 0, bonuses: 0, advances: 0 }), [rows]);
  const employee = data.employees.find((e) => e.id === form.employee_id); const preview = employee ? calculateNetSalary({ ...employee, ...form }) : 0;
  async function create(e) { e.preventDefault(); setError(""); setSuccess(""); if (!employee) return setError("اختر الموظف"); const payload = { employee_id: employee.id, payroll_month: `${form.payroll_month}-01`, base_salary: number(employee.base_salary), housing_allowance: number(employee.housing_allowance), transport_allowance: number(employee.transport_allowance), other_allowance: number(employee.other_allowance), overtime_hours: number(form.overtime_hours), overtime_rate: number(form.overtime_rate), deductions: number(form.deductions), bonuses: permissions.payroll_bonus_manage ? number(form.bonuses) : 0, advances: number(form.advances), notes: form.notes || null, created_by: profile.id }; const mutationResult = await supabase.from("payroll").insert(payload); const result = await syncMutation({ scope: "payroll:create", mutationResult, refetch: () => refresh("payroll") }); if (result.error) return setError(result.error.message); setShowForm(false); setForm(initialPayroll); setSuccess("تم إنشاء مسير الراتب بنجاح"); }
  async function setWorkflow(row, next) { setError(""); setSuccess(""); const mutationResult = await supabase.from("payroll").update({ status: next }).eq("id", row.id); const result = await syncMutation({ scope: `payroll:${next}`, mutationResult, refetch: () => refresh("payroll") }); if (result.error) setError(result.error.message); else setSuccess(next === "paid" ? "تم تسجيل صرف الراتب بنجاح" : "تم تحديث حالة الراتب بنجاح"); return result; }
  async function remove(row) { if (row.status !== "draft") return setError("لا يمكن حذف راتب معتمد أو مدفوع. استخدم مسار العكس أو التصحيح."); if (!window.confirm("حذف مسودة الراتب؟")) return; setError(""); setSuccess(""); const mutationResult = await supabase.from("payroll").delete().eq("id", row.id); const result = await syncMutation({ scope: "payroll:delete", mutationResult, refetch: () => refresh("payroll") }); if (result.error) return setError(result.error.message); setSuccess("تم حذف مسير الراتب بنجاح"); }
  return <div><PageTitle eyebrow="المحاسبة · مسير شهري" title="الرواتب" description="إنشاء واعتماد وصرف الرواتب مع تقارير الخصومات والمكافآت والسلف." actions={<PermissionGuard allow={permissions.payroll_create}><Button onClick={() => setShowForm(true)}><Plus size={16}/> إنشاء راتب</Button></PermissionGuard>}/><ErrorState error={error}/>
    <div className="v22-grid cols-5 payroll-stats"><StatCard label="صافي الرواتب" value={money(totals.net)}/><StatCard label="الخصومات" value={money(totals.deductions)} tone="negative"/><StatCard label="المكافآت" value={money(totals.bonuses)} tone="positive"/><StatCard label="السلف" value={money(totals.advances)}/><StatCard label="غير مدفوع" value={money(rows.filter((p) => p.status !== "paid").reduce((s, p) => s + number(p.net_salary), 0))}/></div>
    <Panel><div className="v22-filters"><Input type="month" value={month} onChange={(e) => setMonth(e.target.value)}/><Select value={status} onChange={(e) => setStatus(e.target.value)}><option value="">كل الحالات</option>{Object.entries(PAYROLL_STATUS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></div>{rows.length ? <DataTable headers={["الموظف", "الشهر", "إضافي", "خصومات", "مكافآت", "سلف", "الصافي", "الحالة", "إجراءات"]}>{rows.map((p) => { const emp = data.employees.find((e) => e.id === p.employee_id); const canSeeBonus = isAdministrativeRole(profile.role) || p.status !== "draft"; return <tr key={p.id}><td>{emp?.full_name || "موظف محذوف"}</td><td>{p.payroll_month?.slice(0, 7)}</td><td>{money(p.overtime_amount)}</td><td>{money(p.deductions)}</td><td>{canSeeBonus ? money(p.bonuses) : "محجوب حتى الاعتماد"}</td><td>{money(p.advances)}</td><td><strong>{money(p.net_salary)}</strong></td><td><span className={`payroll-status ${p.status}`}>{PAYROLL_STATUS[p.status]}</span></td><td><div className="v22-actions"><PermissionGuard allow={p.status === "draft" && permissions.payroll_approve}><Button onClick={() => setWorkflow(p, "approved")}><BadgeCheck size={14}/> اعتماد</Button></PermissionGuard><PermissionGuard allow={p.status === "approved" && permissions.payroll_mark_paid}><Button onClick={() => setPendingPaid(p)}><Banknote size={14}/> صرف</Button></PermissionGuard>{isAdministrativeRole(profile.role) && p.status === "draft" && <button className="v22-icon-button danger" onClick={() => remove(p)}><Trash2 size={15}/></button>}</div></td></tr>; })}</DataTable> : <EmptyState title="لا يوجد مسير رواتب للشهر المحدد"/>}</Panel>
    {showForm && <div className="v22-modal-backdrop"><form className="v22-modal" onSubmit={create}><h3>إنشاء مسير راتب</h3><div className="v22-form-grid"><Field label="الموظف"><Select required value={form.employee_id} onChange={(e) => setForm({ ...form, employee_id: e.target.value })}><option value="">اختر الموظف</option>{data.employees.filter((e) => e.status === "active").map((e) => <option key={e.id} value={e.id}>{e.full_name}</option>)}</Select></Field><Field label="الشهر"><Input required type="month" value={form.payroll_month} onChange={(e) => setForm({ ...form, payroll_month: e.target.value })}/></Field><Field label="ساعات إضافية"><Input type="number" min="0" step=".25" value={form.overtime_hours} onChange={(e) => setForm({ ...form, overtime_hours: e.target.value })}/></Field><Field label="سعر الساعة الإضافية"><Input type="number" min="0" value={form.overtime_rate} onChange={(e) => setForm({ ...form, overtime_rate: e.target.value })}/></Field><Field label="الخصومات"><Input type="number" min="0" value={form.deductions} onChange={(e) => setForm({ ...form, deductions: e.target.value })}/></Field><PermissionGuard allow={permissions.payroll_bonus_manage}><Field label="المكافآت"><Input type="number" min="0" value={form.bonuses} onChange={(e) => setForm({ ...form, bonuses: e.target.value })}/></Field></PermissionGuard><Field label="السلف"><Input type="number" min="0" value={form.advances} onChange={(e) => setForm({ ...form, advances: e.target.value })}/></Field><Field label="ملاحظات" wide><TextArea value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })}/></Field></div>{employee && <div className="payroll-preview"><span>صافي الراتب المتوقع</span><strong>{money(preview)}</strong></div>}<ErrorState error={error}/><div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={() => setShowForm(false)}>إلغاء</Button><Button>حفظ كمسودة</Button></div></form></div>}
    <ConfirmDialog open={Boolean(pendingPaid)} title="تأكيد صرف الراتب" description={`سيتم تعليم راتب ${data.employees.find((e) => e.id === pendingPaid?.employee_id)?.full_name || "الموظف"} بقيمة ${money(pendingPaid?.net_salary)} كمدفوع. هل تم تنفيذ التحويل بالفعل؟`} confirmLabel="نعم، تم الصرف" onCancel={() => setPendingPaid(null)} onConfirm={async () => { const result = await setWorkflow(pendingPaid, "paid"); if (!result.error) setPendingPaid(null); }}/>
    <Toast message={success} onDismiss={() => setSuccess("")}/>
  </div>;
}
