import React, { useMemo, useState } from "react";
import { ArrowRight, Calendar, Download, Eye, File, FolderOpen, MapPin, Paperclip, Pencil, Plus, Trash2, Upload } from "lucide-react";
import { supabase } from "../supabaseClient";
import { Button, ConfirmDialog, DataTable, EmptyState, ErrorState, Field, Input, money, number, PageTitle, Panel, PermissionGuard, Select, StatCard, SuccessState, TextArea, today } from "./shared";

export const PROJECT_STATUSES = {
  design: "التصميم", approval: "الاعتماد", manufacturing: "التصنيع", painting: "الدهان",
  installation: "التركيب", delivered: "تم التسليم", on_hold: "متوقف", cancelled: "ملغي",
};
export const FILE_CATEGORIES = {
  "2d": "رسومات 2D", "3d": "تصميمات 3D", measurements: "المقاسات", cutting_list: "قوائم التقطيع",
  approvals: "الاعتمادات", site_photos: "صور الموقع", other: "أخرى",
};

export function ProjectStatusBadge({ status }) {
  return <span className={`project-status status-${status}`}>{PROJECT_STATUSES[status] || status}</span>;
}
export function ProgressBar({ value = 0 }) {
  const safe = Math.min(100, Math.max(0, number(value)));
  return <div className="project-progress" aria-label={`نسبة الإنجاز ${safe}%`}><span style={{ width: `${safe}%` }} /><b>{safe}%</b></div>;
}

export function ProjectCard({ project, customer, showFinancials, onOpen }) {
  return <button className="project-card" onClick={onOpen}>
    <div className="project-card-head"><div><small>{project.project_code}</small><h3>{project.project_name}</h3></div><ProjectStatusBadge status={project.status} /></div>
    <div className="project-meta"><span><MapPin size={14} />{project.location || "بدون موقع"}</span><span><Calendar size={14} />{project.delivery_date || "غير محدد"}</span></div>
    {customer && <div className="project-customer">العميل: {customer.name}</div>}
    <ProgressBar value={project.progress_percentage} />
    {showFinancials && <div className="project-card-finance"><span>التكلفة الفعلية <b>{money(project.actual_cost)}</b></span><span>الربح <b className={number(project.profit) >= 0 ? "positive" : "negative"}>{money(project.profit)}</b></span></div>}
  </button>;
}

const emptyProject = { project_code: "", project_name: "", customer_id: "", location: "", start_date: today(), delivery_date: "", status: "design", progress_percentage: 0, expected_cost: 0, revenue: 0, notes: "" };

export function ProjectsTab({ data, profile, permissions, refresh, initialProjectId = null }) {
  const [selectedId, setSelectedId] = useState(initialProjectId);
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState(emptyProject);
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("");
  const [customer, setCustomer] = useState("");
  const [fromDate, setFromDate] = useState("");
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const selected = data.projects.find((row) => row.id === selectedId);
  const projects = useMemo(() => data.projects.filter((project) => {
    const q = search.trim().toLowerCase();
    return (!q || `${project.project_code} ${project.project_name} ${project.location || ""}`.toLowerCase().includes(q))
      && (!status || project.status === status) && (!customer || project.customer_id === customer)
      && (!fromDate || project.start_date >= fromDate);
  }), [data.projects, search, status, customer, fromDate]);

  async function createProject(e) {
    e.preventDefault(); setError(""); setSuccess("");
    const payload = { ...form, customer_id: form.customer_id || null, delivery_date: form.delivery_date || null,
      progress_percentage: number(form.progress_percentage), expected_cost: number(form.expected_cost), revenue: number(form.revenue), created_by: profile.id };
    const { data: created, error: createError } = await supabase.from("projects").insert(payload).select().single();
    if (createError) return setError(createError.message);
    setForm(emptyProject); setShowForm(false); setSuccess("تم إنشاء المشروع بنجاح"); await refresh("projects"); setSelectedId(created.id);
  }

  if (selected) return <ProjectDetails project={selected} data={data} profile={profile} permissions={permissions} refresh={refresh} onBack={() => setSelectedId(null)} />;
  return <div>
    <PageTitle eyebrow="V2.2 · إدارة المشروعات" title="المشاريع" description="متابعة كل مشروع من التصميم حتى التسليم مع التكلفة والملفات وسجل النشاط."
      actions={<PermissionGuard allow={permissions.projects_create}><Button onClick={() => setShowForm(true)}><Plus size={16} /> مشروع جديد</Button></PermissionGuard>} />
    <ErrorState error={error} /><SuccessState message={success} />
    <Panel className="v22-filters">
      <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="ابحث بالكود أو اسم المشروع..." />
      <Select value={status} onChange={(e) => setStatus(e.target.value)}><option value="">كل الحالات</option>{Object.entries(PROJECT_STATUSES).map(([key, label]) => <option key={key} value={key}>{label}</option>)}</Select>
      <Select value={customer} onChange={(e) => setCustomer(e.target.value)}><option value="">كل العملاء</option>{data.customers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>
      <Input type="date" value={fromDate} onChange={(e) => setFromDate(e.target.value)} aria-label="من تاريخ" />
    </Panel>
    {projects.length ? <div className="projects-grid">{projects.map((project) => <ProjectCard key={project.id} project={project} customer={data.customers.find((c) => c.id === project.customer_id)} showFinancials={permissions.project_financials_view} onOpen={() => setSelectedId(project.id)} />)}</div> : <Panel><EmptyState title="لا توجد مشاريع مطابقة" description="غيّر عوامل البحث أو أضف مشروعًا جديدًا." /></Panel>}
    {showForm && <div className="v22-modal-backdrop"><form className="v22-modal" onSubmit={createProject}>
      <h3>إنشاء مشروع جديد</h3><div className="v22-form-grid">
        <Field label="كود المشروع"><Input required value={form.project_code} onChange={(e) => setForm({ ...form, project_code: e.target.value })} /></Field>
        <Field label="اسم المشروع"><Input required value={form.project_name} onChange={(e) => setForm({ ...form, project_name: e.target.value })} /></Field>
        <Field label="العميل"><Select value={form.customer_id} onChange={(e) => setForm({ ...form, customer_id: e.target.value })}><option value="">بدون عميل</option>{data.customers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
        <Field label="الموقع"><Input value={form.location} onChange={(e) => setForm({ ...form, location: e.target.value })} /></Field>
        <Field label="تاريخ البدء"><Input type="date" value={form.start_date} onChange={(e) => setForm({ ...form, start_date: e.target.value })} /></Field>
        <Field label="موعد التسليم"><Input type="date" value={form.delivery_date} onChange={(e) => setForm({ ...form, delivery_date: e.target.value })} /></Field>
        <PermissionGuard allow={permissions.project_financials_view}><Field label="التكلفة المتوقعة"><Input type="number" min="0" value={form.expected_cost} onChange={(e) => setForm({ ...form, expected_cost: e.target.value })} /></Field><Field label="الإيراد"><Input type="number" min="0" value={form.revenue} onChange={(e) => setForm({ ...form, revenue: e.target.value })} /></Field></PermissionGuard>
        <Field label="ملاحظات" wide><TextArea value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} /></Field>
      </div><ErrorState error={error} /><div className="v22-actions modal-actions"><Button type="button" variant="ghost" onClick={() => setShowForm(false)}>إلغاء</Button><Button type="submit">حفظ المشروع</Button></div>
    </form></div>}
  </div>;
}

function ProjectDetails({ project, data, profile, permissions, refresh, onBack }) {
  const [editing, setEditing] = useState(false); const [error, setError] = useState(""); const [confirmDelete, setConfirmDelete] = useState(false);
  const [patch, setPatch] = useState({ status: project.status, progress_percentage: project.progress_percentage, expected_cost: project.expected_cost, revenue: project.revenue, notes: project.notes || "" });
  const costs = data.projectCosts.filter((c) => c.project_id === project.id);
  const costsByType = Object.fromEntries(["material","production","payroll","daily_labor","expense","transport","other"].map((type) => [type, costs.filter((c) => c.cost_type === type).reduce((sum, c) => sum + number(c.amount), 0)]));
  const actual = Object.values(costsByType).reduce((a, b) => a + b, 0);
  const profit = number(project.revenue) - actual; const margin = number(project.revenue) ? profit / number(project.revenue) * 100 : 0;
  async function save() {
    setError(""); const update = { progress_percentage: number(patch.progress_percentage), notes: patch.notes };
    if (profile.role === "manager") update.status = patch.status;
    if (permissions.project_financials_view && profile.role !== "production") Object.assign(update, { expected_cost: number(patch.expected_cost), revenue: number(patch.revenue) });
    const { error: e } = await supabase.from("projects").update(update).eq("id", project.id); if (e) return setError(e.message); await refresh("projects"); await refresh("projectActivities"); setEditing(false);
  }
  async function remove() { const { error: e } = await supabase.from("projects").delete().eq("id", project.id); if (e) return setError(e.message); await refresh("projects"); onBack(); }
  return <div>
    <PageTitle eyebrow={project.project_code} title={project.project_name} description={project.location || "لا يوجد موقع مسجل"} actions={<><Button variant="ghost" onClick={onBack}><ArrowRight size={16} /> كل المشاريع</Button><Button variant="ghost" onClick={() => setEditing(!editing)}><Pencil size={15} /> تحديث</Button><PermissionGuard allow={permissions.projects_delete}><Button variant="danger" onClick={() => setConfirmDelete(true)}><Trash2 size={15} /> حذف</Button></PermissionGuard></>} />
    <div className="project-detail-heading"><ProjectStatusBadge status={project.status} /><ProgressBar value={project.progress_percentage} /></div><ErrorState error={error} />
    {editing && <Panel className="project-edit"><div className="v22-form-grid">
      <PermissionGuard allow={profile.role === "manager"}><Field label="الحالة"><Select value={patch.status} onChange={(e) => setPatch({ ...patch, status: e.target.value })}>{Object.entries(PROJECT_STATUSES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field></PermissionGuard>
      <Field label="نسبة الإنجاز"><Input type="number" min="0" max="100" value={patch.progress_percentage} onChange={(e) => setPatch({ ...patch, progress_percentage: e.target.value })} /></Field>
      <PermissionGuard allow={permissions.project_financials_view && profile.role !== "production"}><Field label="التكلفة المتوقعة"><Input type="number" value={patch.expected_cost} onChange={(e) => setPatch({ ...patch, expected_cost: e.target.value })} /></Field><Field label="الإيراد"><Input type="number" value={patch.revenue} onChange={(e) => setPatch({ ...patch, revenue: e.target.value })} /></Field></PermissionGuard>
      <Field label="الملاحظات" wide><TextArea value={patch.notes} onChange={(e) => setPatch({ ...patch, notes: e.target.value })} /></Field>
    </div><div className="v22-actions"><Button onClick={save}>حفظ التحديث</Button></div></Panel>}
    <PermissionGuard allow={permissions.project_financials_view}><div className="v22-grid cols-5 project-stats"><StatCard label="التكلفة المتوقعة" value={money(project.expected_cost)} /><StatCard label="التكلفة الفعلية" value={money(actual)} /><StatCard label="الإيراد" value={money(project.revenue)} /><StatCard label="الربح" value={money(profit)} tone={profit >= 0 ? "positive" : "negative"} /><StatCard label="هامش الربح" value={`${margin.toFixed(1)}%`} /></div></PermissionGuard>
    <div className="project-detail-grid">
      <div className="v22-grid"><ProjectTimeline activities={data.projectActivities.filter((a) => a.project_id === project.id)} /><RelatedProjectData project={project} data={data} permissions={permissions} costs={costsByType} /></div>
      <div><FileUploader project={project} files={data.projectFiles.filter((f) => f.project_id === project.id)} permissions={permissions} profile={profile} refresh={refresh} /></div>
    </div>
    <ConfirmDialog open={confirmDelete} danger title="حذف المشروع؟" description="سيتم حذف المشروع وكل الملفات والأنشطة المرتبطة به. لا يمكن التراجع عن ذلك." confirmLabel="حذف نهائي" onCancel={() => setConfirmDelete(false)} onConfirm={remove} />
  </div>;
}

function ProjectTimeline({ activities }) {
  return <Panel><h3 className="v22-section-title">الخط الزمني والنشاط</h3>{activities.length ? <div className="project-timeline">{[...activities].sort((a,b) => new Date(b.created_at)-new Date(a.created_at)).map((a) => <div key={a.id}><i /><div><strong>{a.description}</strong><span>{new Date(a.created_at).toLocaleString("ar-EG")}</span></div></div>)}</div> : <EmptyState title="لا يوجد نشاط بعد" />}</Panel>;
}

function RelatedProjectData({ project, data, permissions, costs }) {
  const orders = data.productionOrders.filter((x) => x.project_id === project.id); const labor = data.dailyLabor.filter((x) => x.project_id === project.id); const expenses = data.expenses.filter((x) => x.project_id === project.id);
  return <Panel><h3 className="v22-section-title">التكلفة والبيانات المرتبطة</h3><div className="related-counts"><span>أوامر الإنتاج <b>{orders.length}</b></span><span>ورديات العمالة <b>{labor.length}</b></span><span>المصروفات <b>{expenses.length}</b></span><span>الملفات <b>{data.projectFiles.filter((f) => f.project_id === project.id).length}</b></span></div>
    <PermissionGuard allow={permissions.project_financials_view}><div className="cost-breakdown">{Object.entries({ material:"مواد", production:"إنتاج", payroll:"توزيع رواتب", daily_labor:"عمالة يومية", expense:"مصروفات", transport:"نقل", other:"أخرى" }).map(([key,label]) => <div key={key}><span>{label}</span><b>{money(costs[key])}</b></div>)}</div></PermissionGuard>
  </Panel>;
}

export function FileUploader({ project, files, permissions, profile, refresh }) {
  const [file, setFile] = useState(null); const [category, setCategory] = useState("other"); const [description, setDescription] = useState(""); const [busy, setBusy] = useState(false); const [error, setError] = useState("");
  async function upload(e) {
    e.preventDefault(); if (!file) return; setError(""); setBusy(true);
    const ext = file.name.split(".").pop()?.toLowerCase(); const allowed = ["pdf","jpg","jpeg","png","webp","dwg","dxf","xls","xlsx","doc","docx","zip"];
    if (!allowed.includes(ext)) { setBusy(false); return setError("نوع الملف غير مدعوم"); }
    const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "-"); const path = `${project.id}/${crypto.randomUUID()}-${safeName}`;
    const { error: storageError } = await supabase.storage.from("project-files").upload(path, file, { contentType: file.type || "application/octet-stream" });
    if (storageError) { setBusy(false); return setError(storageError.message); }
    const { error: rowError } = await supabase.from("project_files").insert({ project_id: project.id, file_name: file.name, file_path: path, file_type: file.type || ext, file_size: file.size, category, description: description || null, uploaded_by: profile.id });
    if (rowError) { await supabase.storage.from("project-files").remove([path]); setBusy(false); return setError(rowError.message); }
    await supabase.from("project_activities").insert({ project_id: project.id, actor_id: profile.id, action_type: "file_uploaded", description: `تم رفع الملف ${file.name}`, metadata: { category, path } });
    setFile(null); setDescription(""); setBusy(false); await refresh("projectFiles"); await refresh("projectActivities");
  }
  return <Panel><div className="files-heading"><h3 className="v22-section-title"><Paperclip size={17} /> ملفات المشروع</h3><span>{files.length} ملف</span></div>
    <PermissionGuard allow={permissions.project_files_upload}><form className="file-upload-form" onSubmit={upload}><label className="file-drop"><Upload size={22} /><span>{file?.name || "اختر ملفًا أو اسحبه هنا"}</span><input type="file" accept=".pdf,.jpg,.jpeg,.png,.webp,.dwg,.dxf,.xls,.xlsx,.doc,.docx,.zip" onChange={(e) => setFile(e.target.files?.[0] || null)} /></label><Select value={category} onChange={(e) => setCategory(e.target.value)}>{Object.entries(FILE_CATEGORIES).map(([k,v]) => <option key={k} value={k}>{v}</option>)}</Select><Input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="وصف اختياري" /><Button disabled={!file || busy}>{busy ? "جارِ الرفع..." : "رفع الملف"}</Button></form></PermissionGuard>
    <ErrorState error={error} /><FileList files={files} canDelete={permissions.project_files_delete} onRefresh={() => refresh("projectFiles")} />
  </Panel>;
}

export function FileList({ files, canDelete, onRefresh }) {
  const [error, setError] = useState("");
  async function openFile(file, download = false) { const { data, error: e } = await supabase.storage.from("project-files").createSignedUrl(file.file_path, 300, { download }); if (e) return setError(e.message); window.open(data.signedUrl, "_blank", "noopener,noreferrer"); }
  async function remove(file) { if (!window.confirm(`حذف ${file.file_name}؟`)) return; const { error: e } = await supabase.storage.from("project-files").remove([file.file_path]); if (e) return setError(e.message); const { error: dbError } = await supabase.from("project_files").delete().eq("id", file.id); if (dbError) return setError(dbError.message); onRefresh(); }
  if (!files.length) return <EmptyState title="لا توجد ملفات" description="ستظهر الرسومات والمستندات هنا بعد رفعها." />;
  return <div className="file-groups"><ErrorState error={error} />{Object.entries(FILE_CATEGORIES).map(([key,label]) => { const group = files.filter((f) => f.category === key); if (!group.length) return null; return <div key={key}><h4>{label}<span>{group.length}</span></h4>{group.map((file) => <div className="file-row" key={file.id}><div className="file-icon"><File size={18} /></div><div className="file-name"><strong>{file.file_name}</strong><span>{(file.file_size / 1024 / 1024).toFixed(2)} MB · {file.description || "بدون وصف"}</span></div><button className="v22-icon-button" onClick={() => openFile(file)} title="فتح"><Eye size={16} /></button><button className="v22-icon-button" onClick={() => openFile(file, true)} title="تنزيل"><Download size={16} /></button>{canDelete && <button className="v22-icon-button danger" onClick={() => remove(file)} title="حذف"><Trash2 size={16} /></button>}</div>)}</div>; })}</div>;
}

export function ProjectFilesHub({ data, permissions }) {
  const [projectId, setProjectId] = useState(""); const files = projectId ? data.projectFiles.filter((f) => f.project_id === projectId) : data.projectFiles;
  return <div><PageTitle eyebrow="مكتبة المستندات" title="ملفات المشاريع" description="الوصول السريع لكل الرسومات وملفات العمل." /><Panel><div className="v22-filters"><Select value={projectId} onChange={(e) => setProjectId(e.target.value)}><option value="">كل المشاريع</option>{data.projects.map((p) => <option key={p.id} value={p.id}>{p.project_code} · {p.project_name}</option>)}</Select></div><FileList files={files} canDelete={permissions.project_files_delete} onRefresh={() => window.location.reload()} /></Panel></div>;
}
