import React, { useMemo, useState } from "react";
import { Calendar, Download, Eye, File, MapPin, Paperclip, Plus, Trash2, Upload } from "lucide-react";
import { supabase } from "../supabaseClient";
import { Button, EmptyState, ErrorState, Field, Input, money, number, PageTitle, Panel, PermissionGuard, Select, SuccessState, TextArea, Toast, today } from "./shared";
import { buildProjectFilePath, FILE_CATEGORIES, isSupportedProjectFile, PROJECT_FILES_ACCEPT, PROJECT_FILES_BUCKET, PROJECT_FILES_TABLE } from "./fileTypes";
import { syncMutation } from "./mutations";
import { PROJECT_EXECUTION_STAGES, PROJECT_LIFECYCLES } from "./projectDomain";
import { ProjectWorkspace } from "./projectWorkspace";

export const PROJECT_STATUSES = PROJECT_EXECUTION_STAGES;
export { FILE_CATEGORIES } from "./fileTypes";

export function ProjectStatusBadge({ status }) {
  return <span className={`project-status status-${status}`}>{PROJECT_STATUSES[status] || status}</span>;
}
export function ProgressBar({ value = 0 }) {
  const safe = Math.min(100, Math.max(0, number(value)));
  return <div className="project-progress" aria-label={`نسبة الإنجاز ${safe}%`}><span style={{ width: `${safe}%` }} /><b>{safe}%</b></div>;
}

export function ProjectCard({ project, customer, showFinancials, onOpen }) {
  return <button className="project-card" onClick={onOpen}>
    <div className="project-card-head"><div><small>{project.project_code}</small><h3>{project.project_name}</h3></div><div className="project-card-badges"><span className={`project-status lifecycle-${project.lifecycle}`}>{PROJECT_LIFECYCLES[project.lifecycle] || "مشروع قائم"}</span><ProjectStatusBadge status={project.execution_stage || project.status} /></div></div>
    <div className="project-meta"><span><MapPin size={14} />{project.location || "بدون موقع"}</span><span><Calendar size={14} />{project.delivery_date || "غير محدد"}</span></div>
    {customer && <div className="project-customer">العميل: {customer.name}</div>}
    <ProgressBar value={project.effective_progress_percentage ?? project.progress_percentage} />
    {showFinancials && <div className="project-card-finance"><span>التكلفة الفعلية <b>{money(project.actual_cost)}</b></span><span>الربح <b className={number(project.profit) >= 0 ? "positive" : "negative"}>{money(project.profit)}</b></span></div>}
  </button>;
}

const emptyProject = { project_code: "", project_name: "", customer_id: "", location: "", start_date: today(), delivery_date: "", priority:"normal", expected_cost: 0, revenue: 0, notes: "" };

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
      expected_cost: number(form.expected_cost), revenue: number(form.revenue) };
    const mutationResult = await supabase.rpc("create_project_draft", { payload });
    const result = await syncMutation({ scope:"projects:create", mutationResult, refetch:()=>refresh("projects") });
    if (result.error) return setError(result.error.message);
    const activityRefetchResult = await refresh("projectActivities");
    console.info("[projects:create] activityRefetchResult", activityRefetchResult);
    if (activityRefetchResult?.error) return setError(activityRefetchResult.error.message);
    setForm(emptyProject); setShowForm(false); setSuccess("تم إنشاء مسودة المشروع بنجاح"); setSelectedId(mutationResult.data.id);
  }

  if (selected) return <ProjectDetails project={selected} data={data} profile={profile} permissions={permissions} refresh={refresh} onBack={() => setSelectedId(null)} />;
  return <div>
    <PageTitle eyebrow="Project Workspace" title="المشاريع" description="إدارة دورة حياة المشروع ومراحل التنفيذ والفريق والملفات والروابط التشغيلية من مساحة واحدة."
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

function ProjectDetails(props) { return <ProjectWorkspace {...props} FileUploader={FileUploader} ProjectTimeline={ProjectTimeline}/>; }

export function ProjectTimeline({ activities }) {
  return <Panel><h3 className="v22-section-title">الخط الزمني والنشاط</h3>{activities.length ? <div className="project-timeline">{[...activities].sort((a,b) => new Date(b.created_at)-new Date(a.created_at)).map((a) => <div key={a.id}><i /><div><strong>{a.description}</strong><span>{new Date(a.created_at).toLocaleString("ar-EG")}</span></div></div>)}</div> : <EmptyState title="لا يوجد نشاط بعد" />}</Panel>;
}

export function FileUploader({ project, files, permissions, profile, refresh }) {
  const [file, setFile] = useState(null); const [category, setCategory] = useState("other"); const [description, setDescription] = useState(""); const [busy, setBusy] = useState(false); const [error, setError] = useState(""); const [success, setSuccess] = useState("");
  async function upload(e) {
    e.preventDefault();
    setError(""); setSuccess("");
    if (!file) return setError("اختر ملفًا للرفع أولًا");

    const projectId = typeof project?.id === "string" ? project.id.trim() : "";
    const bucketName = PROJECT_FILES_BUCKET;
    console.info("[ProjectFiles] upload context", { projectId, bucketName });
    if (!projectId) {
      console.error("[ProjectFiles] invalid projectId", { projectId, project });
      return setError("تعذر رفع الملف: معرف المشروع غير صالح. أعد فتح المشروع وحاول مرة أخرى.");
    }
    if (!profile?.id) {
      console.error("[ProjectFiles] missing uploaded_by", { projectId, profile });
      return setError("تعذر رفع الملف: بيانات المستخدم غير مكتملة. سجّل الدخول مرة أخرى.");
    }
    const ext = file.name.split(".").pop()?.toLowerCase();
    if (!isSupportedProjectFile(file.name)) return setError("نوع الملف غير مدعوم");

    setBusy(true);
    const filePath = buildProjectFilePath(projectId, file.name);
    console.info("[ProjectFiles] filePath", { projectId, bucketName, filePath });

    try {
      const uploadResult = await supabase.storage.from(bucketName).upload(filePath, file, { contentType: file.type || "application/octet-stream" });
      console.info("[ProjectFiles] uploadResult", uploadResult);
      if (uploadResult.error) {
        console.error("[ProjectFiles] storage upload failed", uploadResult.error);
        return setError(`فشل رفع الملف إلى التخزين: ${uploadResult.error.message}`);
      }

      const createdAt = new Date().toISOString();
      const fileRecord = {
        project_id: projectId, file_name: file.name, file_path: filePath,
        file_type: file.type || ext || "application/octet-stream", file_size: file.size,
        category, description: description.trim() || null, uploaded_by: profile.id, created_at: createdAt,
      };
      const insertResult = await supabase.from(PROJECT_FILES_TABLE).insert(fileRecord).select("*").single();
      console.info("[ProjectFiles] insertResult", insertResult);
      if (insertResult.error || !insertResult.data) {
        console.error("[ProjectFiles] database insert failed", insertResult.error, fileRecord);
        const rollbackResult = await supabase.storage.from(bucketName).remove([filePath]);
        if (rollbackResult.error) console.error("[ProjectFiles] storage rollback failed", rollbackResult.error);
        return setError(`تم إلغاء الرفع لأن حفظ بيانات الملف فشل: ${insertResult.error?.message || "لم يرجع السجل المحفوظ"}`);
      }

      const fetchResult = await refresh("projectFiles");
      console.info("[ProjectFiles] fetchResult", fetchResult);
      if (fetchResult?.error) {
        console.error("[ProjectFiles] refetch failed", fetchResult.error);
        return setError(`تم حفظ الملف لكن تعذر تحديث القائمة: ${fetchResult.error.message}`);
      }
      await refresh("projectActivities");
      setFile(null); setDescription("");
      setSuccess(`تم رفع وحفظ الملف «${file.name}» بنجاح.`);
    } catch (unexpectedError) {
      console.error("[ProjectFiles] unexpected upload error", unexpectedError);
      setError(`حدث خطأ غير متوقع أثناء رفع الملف: ${unexpectedError?.message || "خطأ غير معروف"}`);
    } finally {
      setBusy(false);
    }
  }
  return <Panel><div className="files-heading"><h3 className="v22-section-title"><Paperclip size={17} /> ملفات المشروع</h3><span>{files.length} ملف</span></div>
    <PermissionGuard allow={permissions.project_files_upload}><form className="file-upload-form" onSubmit={upload}><label className="file-drop"><Upload size={22} /><span>{file?.name || "اختر ملفًا أو اسحبه هنا"}</span><small>PDF · صور · DWG/DXF · Office · ZIP (حتى 50 MB)</small><input type="file" accept={PROJECT_FILES_ACCEPT} onChange={(e) => setFile(e.target.files?.[0] || null)} /></label><Select value={category} onChange={(e) => setCategory(e.target.value)}>{Object.entries(FILE_CATEGORIES).map(([k,v]) => <option key={k} value={k}>{v}</option>)}</Select><Input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="وصف اختياري" /><Button disabled={!file || busy}>{busy ? "جارِ الرفع..." : "رفع الملف"}</Button></form></PermissionGuard>
    <Toast type="error" message={error} onDismiss={() => setError("")} /><Toast message={success} onDismiss={() => setSuccess("")} /><FileList files={files} canDelete={permissions.project_files_delete} onRefresh={() => refresh("projectFiles")} />
  </Panel>;
}

export function FileList({ files, canDelete, onRefresh }) {
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  async function openFile(file, download = false) { const { data, error: e } = await supabase.storage.from(PROJECT_FILES_BUCKET).createSignedUrl(file.file_path, 300, { download }); if (e) { console.error("[ProjectFiles] signed URL failed", e); return setError(e.message); } const opened = window.open(data.signedUrl, "_blank"); if (!opened) return setError("تعذر فتح الملف. اسمح بالنوافذ المنبثقة لهذا الموقع وحاول مرة أخرى."); opened.opener = null; }
  async function remove(file) { if (!window.confirm(`حذف ${file.file_name}؟`)) return; setError(""); setSuccess(""); const mutationResult = await supabase.from(PROJECT_FILES_TABLE).delete().eq("id", file.id); const result=await syncMutation({scope:"projectFiles:delete",mutationResult,refetch:onRefresh}); if(result.error)return setError(result.error.message); const storageMutationResult = await supabase.storage.from(PROJECT_FILES_BUCKET).remove([file.file_path]); console.info("[ProjectFiles:delete] storage mutationResult",storageMutationResult); if (storageMutationResult.error) { console.error("[ProjectFiles] storage cleanup failed", storageMutationResult.error); setError("تم حذف سجل الملف، لكن تعذر تنظيف الملف من التخزين. راجع مسؤول النظام."); } else setSuccess("تم حذف الملف بنجاح"); }
  if (!files.length) return <><Toast type="error" message={error} onDismiss={()=>setError("")}/><Toast message={success} onDismiss={()=>setSuccess("")}/><EmptyState title="لا توجد ملفات" description="ستظهر الرسومات والمستندات هنا بعد رفعها." /></>;
  return <div className="file-groups"><Toast type="error" message={error} onDismiss={()=>setError("")}/><Toast message={success} onDismiss={()=>setSuccess("")}/>{Object.entries(FILE_CATEGORIES).map(([key,label]) => { const group = files.filter((f) => f.category === key); if (!group.length) return null; return <div key={key}><h4>{label}<span>{group.length}</span></h4>{group.map((file) => <div className="file-row" key={file.id}><div className="file-icon"><File size={18} /></div><div className="file-name"><strong>{file.file_name}</strong><span>{(file.file_size / 1024 / 1024).toFixed(2)} MB · {file.description || "بدون وصف"}</span></div><button className="v22-icon-button" onClick={() => openFile(file)} title="فتح" aria-label={`فتح ${file.file_name}`}><Eye size={16} /></button><button className="v22-icon-button" onClick={() => openFile(file, true)} title="تنزيل" aria-label={`تنزيل ${file.file_name}`}><Download size={16} /></button>{canDelete && <button className="v22-icon-button danger" onClick={() => remove(file)} title="حذف" aria-label={`حذف ${file.file_name}`}><Trash2 size={16} /></button>}</div>)}</div>; })}</div>;
}

export function ProjectFilesHub({ data, permissions, refresh }) {
  const [projectId, setProjectId] = useState(""); const files = projectId ? data.projectFiles.filter((f) => f.project_id === projectId) : data.projectFiles;
  return <div><PageTitle eyebrow="مكتبة المستندات" title="ملفات المشاريع" description="الوصول السريع لكل الرسومات وملفات العمل." /><Panel><div className="v22-filters"><Select value={projectId} onChange={(e) => setProjectId(e.target.value)}><option value="">كل المشاريع</option>{data.projects.map((p) => <option key={p.id} value={p.id}>{p.project_code} · {p.project_name}</option>)}</Select></div><FileList files={files} canDelete={permissions.project_files_delete} onRefresh={() => refresh("projectFiles")} /></Panel></div>;
}
