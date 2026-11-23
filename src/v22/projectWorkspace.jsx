import React, { useEffect, useMemo, useState } from "react";
import { AlertTriangle, ArrowRight, Boxes, CalendarDays, CheckCircle2, ClipboardList, Factory, FileText, Gauge, HardHat, History, Package, Pencil, Plus, ReceiptText, ShieldCheck, Users, Wallet, Wrench } from "lucide-react";
import { supabase } from "../supabaseClient";
import { Button, ConfirmDialog, EmptyState, ErrorState, Field, Input, money, number, PageTitle, Panel, PermissionGuard, Select, StatCard, SuccessState, TextArea } from "./shared";
import {
  calculatedMilestoneProgress, effectiveProjectProgress, lifecycleNeedsReason, lifecycleTransitionsFor,
  MILESTONE_STATUSES, PROJECT_EXECUTION_STAGES, PROJECT_LIFECYCLES, PROJECT_MEMBER_ROLES,
  PROJECT_PRIORITIES, PROJECT_PROGRESS_MODES, projectWorkspaceSummary,
} from "./projectDomain";
import { ProjectBudgetTab } from "./projectBudget";
import { ProjectActualCostTab } from "./projectActualCost";
import { friendlyError } from "../operational/ui";
import "./projectWorkspace.css";

const TABS = [
  ["overview", "نظرة عامة", Gauge], ["milestones", "مراحل التنفيذ", ClipboardList], ["team", "الفريق", Users],
  ["files", "الملفات", FileText], ["materials", "الخامات والمشتريات", Package], ["production", "الإنتاج", Factory],
  ["labor", "العمالة", HardHat], ["expenses", "المصروفات", ReceiptText], ["assets", "العِدّة", Wrench],
  ["budget", "الميزانية", Wallet], ["actualCost", "التكلفة الفعلية", Boxes],
  ["activity", "سجل النشاط", History],
];

const emptyMilestone = { id:"", title:"", description:"", stage_key:"design", sequence:0, weight_percentage:0, responsibleIdentity:"", planned_start_date:"", planned_end_date:"", status:"not_started", progress_percentage:0, blocking_reason:"" };
const emptyMember = { identity:"", project_role:"viewer", start_date:"", end_date:"" };
const WORKFLOW_ACTIONS = {
  prepare_project:"بدء تجهيز المشروع",
  complete_budget_and_details:"استكمال البيانات والميزانية",
  reconcile_project_approval_history:"مراجعة سجل اعتماد المشروع",
  approve_project:"اعتماد المشروع",
  assign_project_manager:"تعيين مدير المشروع",
  start_execution:"بدء التنفيذ",
  resolve_open_dependencies:"معالجة الارتباطات المفتوحة",
  complete_project:"إكمال المشروع",
  close_project:"إغلاق المشروع",
  resume_project:"استئناف المشروع",
  view_history:"عرض السجل",
};

function LifecycleBadge({ value }) { return <span className={`workspace-badge lifecycle-${value}`}>{PROJECT_LIFECYCLES[value] || value}</span>; }
function StageBadge({ value }) { return <span className={`workspace-badge stage-${value}`}>{PROJECT_EXECUTION_STAGES[value] || value}</span>; }
function WorkflowReadiness({ workflow }) {
  const source = workflow?.next_action === "complete_budget_and_details"
    ? workflow.approval_readiness
    : workflow?.next_action === "resolve_open_dependencies"
      ? workflow.completion_readiness
      : workflow?.next_action === "reconcile_project_approval_history"
        ? workflow.approval_reconciliation
        : null;
  const checks = source?.checks || [];
  const blockers = checks.filter((check) => check.blocking ? !check.passed : number(check.count)>0);
  if (!blockers.length) return null;
  return <ul className="project-workflow-blockers">{blockers.map((check) => <li key={check.key}>
    <AlertTriangle size={15}/><div><strong>{check.label}</strong>
      {check.first_record && <span>{check.first_record.number || check.first_record.name} — {check.first_record.status}</span>}
      {check.safe_alternative && <small>{check.safe_alternative}</small>}
    </div>
  </li>)}</ul>;
}

function ProjectPilotWorkflow({ workflow, data, project, busy, managerTarget, setManagerTarget, managerReason, setManagerReason, onAction, onAssign, onClose, onBudget }) {
  if (!workflow) return <Panel className="project-workflow-panel"><h3>مسار اعتماد وتنفيذ المشروع</h3><p>جارٍ تحميل حالة المسار…</p></Panel>;
  const action=workflow.next_action;
  const directAction=["prepare_project","approve_project","start_execution","complete_project","resume_project"].includes(action);
  return <Panel className="project-workflow-panel">
    <div className="project-workflow-head"><div><small>الخطوة التالية</small><h3>{WORKFLOW_ACTIONS[action] || action}</h3></div><LifecycleBadge value={workflow.lifecycle}/></div>
    <ol className="project-workflow-steps">{(workflow.steps || []).map((step) => <li key={step.key} className={step.complete ? "complete" : ""}><CheckCircle2 size={17}/><span>{step.label}</span></li>)}</ol>
    <WorkflowReadiness workflow={workflow}/>
    {action === "complete_budget_and_details" && <Button onClick={onBudget}>فتح الميزانية التقديرية</Button>}
    {directAction && <PermissionGuard allow={workflow.capabilities?.approve || workflow.capabilities?.start || workflow.capabilities?.complete}><Button disabled={busy} onClick={()=>onAction(action)}>{WORKFLOW_ACTIONS[action]}</Button></PermissionGuard>}
    {(action === "assign_project_manager" || project.project_manager_id) && <PermissionGuard allow={workflow.capabilities?.assign_manager}><div className="project-manager-action">
      <Field label={project.project_manager_id ? "تغيير مدير المشروع" : "مدير المشروع"}><Select value={managerTarget} onChange={(event)=>setManagerTarget(event.target.value)}><option value="">اختر حسابًا نشطًا</option>{data.profiles.filter((row)=>row.status==="active").map((row)=><option key={row.id} value={row.id}>{row.full_name || row.email}</option>)}</Select></Field>
      {project.project_manager_id && managerTarget !== project.project_manager_id && <Field label="سبب التغيير"><Input value={managerReason} onChange={(event)=>setManagerReason(event.target.value)} placeholder="سبب إلزامي ومحفوظ في السجل"/></Field>}
      <Button disabled={busy || !managerTarget || managerTarget===project.project_manager_id || (project.project_manager_id && !managerReason.trim())} onClick={onAssign}>{project.project_manager_id ? "حفظ تغيير المدير" : "تعيين المدير"}</Button>
    </div></PermissionGuard>}
    {action === "close_project" && <PermissionGuard allow={workflow.capabilities?.close}><Button disabled={busy} onClick={onClose}>إغلاق المشروع بسبب موثق</Button></PermissionGuard>}
  </Panel>;
}

function IdentityOptions({ data }) {
  const linkedEmployeeIds = new Set(data.profiles.map((profile) => profile.employee_id).filter(Boolean));
  return <>
    <option value="">بدون مسؤول محدد</option>
    <optgroup label="حسابات النظام">{data.profiles.filter((profile) => profile.status === "active").map((profile) => <option key={`profile:${profile.id}`} value={`profile:${profile.id}`}>{profile.full_name || profile.email}</option>)}</optgroup>
    <optgroup label="موظفون بدون حساب">{data.employees.filter((employee) => employee.status === "active" && !linkedEmployeeIds.has(employee.id)).map((employee) => <option key={`employee:${employee.id}`} value={`employee:${employee.id}`}>{employee.full_name}</option>)}</optgroup>
  </>;
}

function resolveIdentity(data, value) {
  const [kind, id] = String(value || "").split(":");
  if (kind === "profile") {
    const profile = data.profiles.find((row) => row.id === id);
    return { profile_id:id || null, employee_id:profile?.employee_id || null };
  }
  if (kind === "employee") {
    const profile = data.profiles.find((row) => row.employee_id === id && row.status === "active");
    return { profile_id:profile?.id || null, employee_id:id || null };
  }
  return { profile_id:null, employee_id:null };
}

function identityLabel(data, profileId, employeeId) {
  const profile = data.profiles.find((row) => row.id === profileId);
  const employee = data.employees.find((row) => row.id === employeeId);
  return profile?.full_name || profile?.email || employee?.full_name || "عضو غير متاح";
}


const PROCUREMENT_STATUS_LABELS = {
  draft:"مسودة", submitted:"بانتظار الاعتماد", approved:"معتمد", rejected:"مرفوض",
  cancelled:"ملغي", converted:"تم التحويل", completed:"مكتمل", received:"عرض مستلم",
  selected:"مختار", partially_received:"استلام جزئي", fully_received:"مستلم بالكامل",
  invoiced:"مفوتر", closed:"مغلق", sent:"مرسل للمورد", confirmed:"مؤكد", matched:"مطابق",
  paid:"مدفوعة", pending:"معلقة",
};

function ProjectMaterialsPurchasesTab({ project, data, canViewFinancials }) {
  const [workspace, setWorkspace] = useState({ orders:[], order_items:[], invoices:[], invoice_lines:[] });
  const [inventory, setInventory] = useState({ items:[], balances:[], warehouses:[], capabilities:{} });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [stockError, setStockError] = useState("");
  const [issueBusy, setIssueBusy] = useState(false);
  const [issueSuccess, setIssueSuccess] = useState("");
  const [selectedBalance, setSelectedBalance] = useState("");
  const [issueQuantity, setIssueQuantity] = useState("");
  const [issueDescription, setIssueDescription] = useState("");

  async function loadPurchases() {
    setLoading(true);
    setError("");
    const [purchaseResult, inventoryResult] = await Promise.all([
      supabase.rpc("get_procurement_workspace_v2", { target_project:project.id }),
      supabase.rpc("get_inventory_workspace"),
    ]);
    if (purchaseResult.error) {
      setError(friendlyError(purchaseResult.error));
      setWorkspace({ orders:[], order_items:[], invoices:[], invoice_lines:[] });
    } else {
      setWorkspace({
        orders:Array.isArray(purchaseResult.data?.orders) ? purchaseResult.data.orders : [],
        order_items:Array.isArray(purchaseResult.data?.order_items) ? purchaseResult.data.order_items : [],
        invoices:Array.isArray(purchaseResult.data?.invoices) ? purchaseResult.data.invoices : [],
        invoice_lines:Array.isArray(purchaseResult.data?.invoice_lines) ? purchaseResult.data.invoice_lines : [],
      });
    }
    if (inventoryResult.error) {
      setStockError(friendlyError(inventoryResult.error));
      setInventory({ items:[], balances:[], warehouses:[], capabilities:{} });
    } else {
      setStockError("");
      setInventory({
        items:Array.isArray(inventoryResult.data?.items) ? inventoryResult.data.items : [],
        balances:Array.isArray(inventoryResult.data?.balances) ? inventoryResult.data.balances : [],
        warehouses:Array.isArray(inventoryResult.data?.warehouses) ? inventoryResult.data.warehouses : [],
        capabilities:inventoryResult.data?.capabilities || {},
      });
    }
    setLoading(false);
  }

  useEffect(() => { void loadPurchases(); }, [project.id]);

  const orders = [...workspace.orders].sort((a,b)=>new Date(b.created_at||b.order_date||0)-new Date(a.created_at||a.order_date||0));
  const supplierName = id => data.suppliers.find(row=>row.id===id)?.name || "مورد غير محدد";
  const materialName = id => data.materials.find(row=>row.id===id)?.name || "";
  const amount = (value,currency) => money(number(value)) + (currency ? " " + currency : "");
  const availableBalances = (inventory.balances || []).filter(row => number(row.quantity_on_hand) > 0);
  const canIssueStock = Boolean(inventory.capabilities?.manage);
  const selectedStock = availableBalances.find(row => row.inventory_item_id + ":" + row.warehouse_id === selectedBalance);
  const selectedItem = selectedStock && inventory.items.find(row => row.id === selectedStock.inventory_item_id);
  const selectedWarehouse = selectedStock && inventory.warehouses.find(row => row.id === selectedStock.warehouse_id);

  async function issueStockToProject() {
    if (!selectedStock) return setStockError("اختر صنفًا ومخزنًا به رصيد متاح.");
    const quantity = Number(issueQuantity);
    if (!Number.isFinite(quantity) || quantity <= 0) return setStockError("أدخل كمية أكبر من صفر.");
    if (quantity > number(selectedStock.quantity_on_hand)) return setStockError("الكمية المطلوبة أكبر من المتاح في المخزن.");
    if (!issueDescription.trim()) return setStockError("اكتب وصف استخدام الخامة في المشروع.");
    setIssueBusy(true);
    setStockError("");
    setIssueSuccess("");
    const result = await supabase.rpc("issue_inventory_to_project", {
      target_inventory_item:selectedStock.inventory_item_id,
      target_warehouse:selectedStock.warehouse_id,
      target_project:project.id,
      issue_quantity:quantity,
      description:issueDescription.trim(),
      budget_item:null,
      milestone:null,
    });
    setIssueBusy(false);
    if (result.error) {
      setStockError(friendlyError(result.error));
      return;
    }
    setIssueSuccess("تم صرف الكمية للمشروع وتسجيل تكلفتها تلقائيًا. لم يتم إنشاء فاتورة مورد أو استلام مخزون جديد.");
    setIssueQuantity("");
    setIssueDescription("");
    await loadPurchases();
  }

  if (loading) return <Panel><p>جارٍ تحميل مشتريات ومخزون المشروع...</p></Panel>;

  return <div className="workspace-section">
    <div className="workspace-section-head">
      <div><h3>الخامات والمشتريات</h3><p>استلام فواتير المورد مركزيًا، ثم صرف الكميات المستهلكة لهذا المشروع من المخزون.</p></div>
      <Button variant="ghost" onClick={loadPurchases}>تحديث البيانات</Button>
    </div>
    <ErrorState error={error}/>
    {error ? <Panel><p>تعذر تحميل سجل المشتريات. لم نعرض رسالة «لا توجد مشتريات» لأن البيانات لم تُحمّل بنجاح.</p></Panel>
      : orders.length ? <div className="milestone-list">{orders.map(order=>{
        const items=workspace.order_items.filter(item=>item.purchase_order_id===order.id);
        const invoices=workspace.invoices.filter(invoice=>invoice.purchase_order_id===order.id);
        return <Panel key={order.id} className="milestone-card">
          <div className="milestone-head">
            <div><small>{order.order_number || "أمر شراء"} · {order.order_date || String(order.created_at||"").slice(0,10) || "—"}</small><h4>{order.display_name || order.order_number || "أمر شراء"}</h4></div>
            <span>{PROCUREMENT_STATUS_LABELS[order.status] || order.status || "—"}</span>
          </div>
          <div className="milestone-meta">
            <span>المورد: {supplierName(order.supplier_id)}</span>
            {canViewFinancials && <span>الإجمالي: {amount(order.total_amount,order.currency)}</span>}
          </div>
          {items.length ? <ul className="workspace-simple-list">{items.map(item=>{
            const knownMaterial=materialName(item.material_id);
            const label=knownMaterial || item.description || "بند مشتريات";
            return <li key={item.id}>
              <span>{label}{item.description && knownMaterial ? " — " + item.description : ""}</span>
              <small>{number(item.quantity)} {item.unit || ""}{canViewFinancials ? " × " + amount(item.unit_price,order.currency) : ""}</small>
            </li>;
          })}</ul> : <p className="workspace-note">لا توجد بنود مسجلة لأمر الشراء.</p>}
          {invoices.length>0 && <div className="workspace-note">فواتير المورد: {invoices.map(invoice=>(invoice.invoice_number || "فاتورة") + " (" + (PROCUREMENT_STATUS_LABELS[invoice.status] || invoice.status) + ")").join("، ")}</div>}
        </Panel>;
      })}</div> : <Panel><EmptyState title="لا توجد مشتريات مرتبطة" description="فواتير المورد والاستلام المركزي يظهران في شاشة المشتريات، ولا يشترط ربطهما بمشروع عند الاستلام." /></Panel>}

    <Panel>
      <div className="workspace-section-head"><div><h3>صرف خامات من المخزون للمشروع</h3><p>اختر الصنف والمخزن والكمية فقط؛ النظام يحسب التكلفة تلقائيًا حسب طريقة تقييم المخزون النشطة.</p></div></div>
      <ErrorState error={stockError}/>
      {issueSuccess && <SuccessState>{issueSuccess}</SuccessState>}
      {!stockError && !availableBalances.length
        ? <EmptyState title="لا توجد كميات متاحة للصرف" description="استلم فاتورة المورد وحوّل الكميات المقبولة إلى المخزون أولًا من شاشة المشتريات."/>
        : <div className="project-manager-action">
          <Field label="الصنف والمخزن والرصيد المتاح">
            <Select value={selectedBalance} onChange={event=>setSelectedBalance(event.target.value)}>
              <option value="">اختر صنفًا من المخزون</option>
              {availableBalances.map(row=>{
                const item=inventory.items.find(entry=>entry.id===row.inventory_item_id);
                return <option key={row.inventory_item_id+":"+row.warehouse_id} value={row.inventory_item_id+":"+row.warehouse_id}>
                  {(item?.name || row.item_name || "صنف مخزون")} — {(inventory.warehouses.find(entry=>entry.id===row.warehouse_id)?.name || row.warehouse_name || "مخزن")} · متاح {number(row.quantity_on_hand)} {item?.unit || ""}
                </option>;
              })}
            </Select>
          </Field>
          <Field label="الكمية المطلوب صرفها">
            <Input type="number" min="0" step="0.0001" value={issueQuantity} onChange={event=>setIssueQuantity(event.target.value)} placeholder="أدخل الكمية"/>
          </Field>
          <Field label="بيان الاستخدام داخل المشروع">
            <Input value={issueDescription} onChange={event=>setIssueDescription(event.target.value)} placeholder="مثال: ألواح مستخدمة في تنفيذ الموقع"/>
          </Field>
          {selectedStock && <p className="workspace-note">المتاح حاليًا: {number(selectedStock.quantity_on_hand)} {selectedItem?.unit || ""} — المخزن: {selectedWarehouse?.name || selectedStock.warehouse_name || "—"}{canViewFinancials ? " — قيمة المخزون الحالية: " + money(number(selectedStock.inventory_value)) : ""}</p>}
          <Button disabled={issueBusy || !selectedStock} onClick={issueStockToProject}>{issueBusy ? "جارٍ تسجيل الصرف…" : "صرف الكمية للمشروع"}</Button>
        </div>}
      <p className="workspace-note">الصرف يخصم الكمية من المخزون مرة واحدة ويسجل تكلفة المشروع باستخدام المتوسط المرجح أو FIFO. لا يعيد تسجيل فاتورة المورد ولا ينشئ استلامًا أو قيد شراء إضافيًا.</p>
    </Panel>
    <Panel className="workspace-note"><p>أوامر الشراء وفواتير المورد تُسجل مركزيًا. هذه الشاشة تعرض المستندات للمتابعة، أما تكلفة الخامات على المشروع فتُسجل عند صرف الكمية الفعلية إليه.</p></Panel>
  </div>;
}

function ProjectExpensesTab({ rows, canViewFinancials, refresh }) {
  const [busyId,setBusyId]=useState("");
  const [error,setError]=useState("");
  const [success,setSuccess]=useState("");

  async function sendToActualCost(row) {
    setBusyId(row.id); setError(""); setSuccess("");
    const result=await supabase.rpc("prepare_operational_source_actual_cost",{
      target_source_type:"approved_expense",
      target_source_id:row.id,
    });
    setBusyId("");
    if(result.error) { setError(friendlyError(result.error)); return; }
    setSuccess("تم إرسال المصروف إلى قيود التكلفة الفعلية للمراجعة والاعتماد.");
    await refresh();
  }

  const statusLabel={not_posted:"غير مُرحّل",submitted:"قيد المراجعة",posted:"مُرحّل",rejected:"مرفوض",reversed:"معكوس"};
  return <Panel>
    <div className="workspace-section-head"><div><h3>المصروفات المرتبطة</h3><p>إرسال المصروفات غير المرحلة إلى مسار مراجعة التكلفة الفعلية.</p></div></div>
    <ErrorState error={error}/>
    {success && <SuccessState>{success}</SuccessState>}
    {!rows.length ? <EmptyState title="لا توجد مصروفات مرتبطة" description="ستظهر هنا المصروفات المسجلة على هذا المشروع."/> :
      <div className="milestone-list">{rows.map(row=><div className="milestone-card" key={row.id}>
        <div className="milestone-head"><div><h4>{row.category || "مصروف"}</h4><small>{row.expense_date || row.created_at?.slice(0,10) || "—"} · {row.notes || "بدون وصف"}</small></div>
          <span>{row.cancelled_at ? "ملغي" : (statusLabel[row.cost_posting_status] || row.cost_posting_status || "غير محدد")}</span>
        </div>
        <div className="milestone-meta">
          {canViewFinancials && <strong>{money(row.amount)}</strong>}
          {row.cost_posting_status==="not_posted" && !row.cancelled_at && <Button disabled={busyId===row.id} onClick={()=>sendToActualCost(row)}>{busyId===row.id ? "جارٍ الإرسال…" : "إرسال للتكلفة الفعلية"}</Button>}
        </div>
      </div>)}</div>}
    <p className="workspace-note">الإرسال ينشئ قيدًا بحالة «قيد المراجعة» فقط؛ لا يدخل ضمن التكلفة المعتمدة إلا بعد اعتماد صاحب الصلاحية. إعادة الإرسال بعد الربط ممنوعة لمنع التكرار.</p>
  </Panel>;
}

export function ProjectWorkspace({ project, data, profile, permissions, refresh, onBack, FileUploader, ProjectTimeline }) {
  const [tab, setTab] = useState("overview");
  const [error, setError] = useState(""); const [success, setSuccess] = useState(""); const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState(false);
  const [details, setDetails] = useState({});
  const [lifecycleTarget, setLifecycleTarget] = useState(""); const [lifecycleReason, setLifecycleReason] = useState("");
  const [stage, setStage] = useState(project.execution_stage || project.status || "design");
  const [progress, setProgress] = useState({ mode:project.progress_mode || "hybrid", manual:project.manual_progress_percentage ?? project.progress_percentage ?? 0, reason:project.progress_override_reason || "" });
  const [milestone, setMilestone] = useState(emptyMilestone); const [showMilestoneForm, setShowMilestoneForm] = useState(false);
  const [member, setMember] = useState(emptyMember); const [showMemberForm, setShowMemberForm] = useState(false);
  const [workflow, setWorkflow] = useState(null);
  const [managerTarget, setManagerTarget] = useState(project.project_manager_id || "");
  const [managerReason, setManagerReason] = useState("");
  const [actionDialog, setActionDialog] = useState(null);
  const summary = useMemo(() => projectWorkspaceSummary(project, data), [project, data]);
  const calculatedProgress = calculatedMilestoneProgress(summary.milestones);
  const effectiveProgress = project.effective_progress_percentage ?? project.progress_percentage ?? effectiveProjectProgress({ mode:progress.mode, manual:progress.manual, calculated:calculatedProgress, overrideReason:progress.reason });
  const customer = data.customers.find((row) => row.id === project.customer_id);
  const manager = data.profiles.find((row) => row.id === project.project_manager_id);
  const actual = number(project.actual_cost);
  const profit = number(project.revenue)-actual; const margin = number(project.revenue) ? (profit/number(project.revenue))*100 : 0;

  useEffect(() => {
    setDetails({ project_name:project.project_name,customer_id:project.customer_id || "",location:project.location || "",start_date:project.start_date || "",delivery_date:project.delivery_date || "",priority:project.priority || "normal",expected_cost:project.expected_cost ?? 0,revenue:project.revenue ?? 0,notes:project.notes || "" });
    setStage(project.execution_stage || project.status || "design");
    setProgress({ mode:project.progress_mode || "hybrid",manual:project.manual_progress_percentage ?? project.progress_percentage ?? 0,reason:project.progress_override_reason || "" });
    setManagerTarget(project.project_manager_id || "");
  }, [project.id, project.updated_at]);

  async function loadWorkflow() {
    const result = await supabase.rpc("get_project_pilot_workflow", { target_project:project.id });
    if (result.error) {
      console.error("[ProjectWorkspace:get_project_pilot_workflow]", result.error);
      setError(friendlyError(result.error));
      return null;
    }
    setWorkflow(result.data);
    return result.data;
  }

  useEffect(() => { loadWorkflow(); }, [project.id, project.updated_at]);

  async function runRpc(name, args, keys, message) {
    setBusy(true); setError(""); setSuccess("");
    try {
      const result = await supabase.rpc(name,args);
      console.info(`[ProjectWorkspace:${name}] mutationResult`,result);
      if (result.error) return setError(friendlyError(result.error));
      const refreshResult = await Promise.all([...new Set(keys)].map((key) => refresh(key)));
      console.info(`[ProjectWorkspace:${name}] refetchResult`,refreshResult);
      const failed = refreshResult.find((entry) => entry?.error);
      if (failed?.error) return setError(`تم الحفظ لكن تعذر تحديث الواجهة: ${friendlyError(failed.error)}`);
      await loadWorkflow();
      setSuccess(message);
      return result.data;
    } catch (unexpected) {
      console.error(`[ProjectWorkspace:${name}] unexpected`,unexpected);
      setError(friendlyError(unexpected));
    } finally { setBusy(false); }
  }

  async function saveDetails() {
    const payload = permissions.project_financials_view
      ? details
      : Object.fromEntries(Object.entries(details).filter(([key])=>!["expected_cost","revenue"].includes(key)));
    const result = await runRpc("update_project_details",{ target_project:project.id,payload },["projects","projectActivities"],"تم تحديث بيانات المشروع.");
    if (result) setEditing(false);
  }
  async function transitionLifecycle() {
    if (!lifecycleTarget) return;
    const result = await runRpc("transition_project_lifecycle",{ target_project:project.id,next_lifecycle:lifecycleTarget,reason:lifecycleReason.trim() || null },["projects","projectActivities"],"تم تحديث دورة حياة المشروع.");
    if (result) { setLifecycleTarget(""); setLifecycleReason(""); }
  }
  async function saveStage() { await runRpc("update_project_execution_stage",{ target_project:project.id,next_stage:stage,reason:null },["projects","projectActivities"],"تم تحديث مرحلة التنفيذ."); }
  async function saveProgress() { await runRpc("update_project_progress",{ target_project:project.id,mode:progress.mode,manual_percentage:progress.mode === "automatic" ? null : number(progress.manual),override_reason:progress.reason.trim() || null },["projects","projectActivities"],"تم تحديث نموذج الإنجاز."); }
  async function saveMilestone() {
    const identity = resolveIdentity(data,milestone.responsibleIdentity);
    const payload = { ...milestone,...identity,project_id:project.id,sequence:number(milestone.sequence),weight_percentage:number(milestone.weight_percentage),progress_percentage:number(milestone.progress_percentage) };
    delete payload.responsibleIdentity;
    const result = await runRpc("save_project_milestone",{ payload },["projectMilestones","projects","projectActivities"],"تم حفظ مرحلة التنفيذ.");
    if (result) { setMilestone(emptyMilestone); setShowMilestoneForm(false); }
  }
  function editMilestone(row) {
    setMilestone({ ...row,responsibleIdentity:row.responsible_profile_id ? `profile:${row.responsible_profile_id}` : row.responsible_employee_id ? `employee:${row.responsible_employee_id}` : "" }); setShowMilestoneForm(true);
  }
  async function cancelMilestone(row) { setActionDialog({type:"milestone",row,reason:""}); }
  async function addMember() {
    const identity=resolveIdentity(data,member.identity);
    const result=await runRpc("add_project_member",{ target_project:project.id,target_profile:identity.profile_id,target_employee:identity.employee_id,member_role:member.project_role,member_start:member.start_date || null,member_end:member.end_date || null },["projectMembers","projects","projectActivities"],"تمت إضافة عضو الفريق.");
    if(result){setMember(emptyMember);setShowMemberForm(false);}
  }
  async function removeMember(row){setActionDialog({type:"member",row,reason:""});}
  async function runWorkflowAction(action) {
    const rpc = {
      prepare_project:["transition_project_lifecycle",{ target_project:project.id,next_lifecycle:"planning",reason:null }],
      approve_project:["approve_project_for_execution",{ target_project:project.id }],
      start_execution:["start_project_execution",{ target_project:project.id }],
      complete_project:["complete_project_execution",{ target_project:project.id }],
      resume_project:["transition_project_lifecycle",{ target_project:project.id,next_lifecycle:"active",reason:null }],
    }[action];
    if (!rpc) return;
    await runRpc(rpc[0],rpc[1],["projects","projectActivities"],"تم تنفيذ الخطوة التالية وحفظها في سجل المشروع.");
  }
  async function assignManager() {
    const result = await runRpc(
      "assign_project_manager_secure",
      { target_project:project.id,target_profile:managerTarget,change_reason:managerReason.trim() || null },
      ["projectMembers","projects","projectActivities"],
      project.project_manager_id ? "تم تغيير مدير المشروع مع حفظ السبب." : "تم تعيين مدير المشروع."
    );
    if (result) setManagerReason("");
  }
  async function closeProject() {
    setActionDialog({type:"close",reason:""});
  }
  async function confirmActionDialog() {
    if (!actionDialog) return;
    const {type,row,reason}=actionDialog;
    if (type!=="member" && !reason.trim()) return;
    const result = type==="milestone"
      ? await runRpc("remove_project_milestone",{target_milestone:row.id,reason:reason.trim()},["projectMilestones","projects","projectActivities"],"تم إلغاء المرحلة مع حفظ تاريخها.")
      : type==="member"
        ? await runRpc("remove_project_member",{target_member:row.id},["projectMembers","projects","projectActivities"],"تمت إزالة عضو الفريق.")
        : await runRpc("close_project_secure",{target_project:project.id,close_reason:reason.trim()},["projects","projectActivities"],"تم إغلاق المشروع وحفظ السبب.");
    if (result) setActionDialog(null);
  }

  const nextLifecycles = lifecycleTransitionsFor(project.lifecycle || "planning").filter((next) => next !== "active" || project.lifecycle !== "completed" || profile.role === "owner");
  const openAssignments = summary.assignments.length;
  const fifthKpi = permissions.project_financials_view
    ? { label:"التكلفة الفعلية",value:money(actual) }
    : { label:"الملفات",value:summary.files.length };

  return <div className="project-workspace" dir="rtl">
    <PageTitle eyebrow={project.project_code} title={project.project_name} description={project.location || "مساحة عمل المشروع"} actions={<><Button variant="ghost" onClick={onBack}><ArrowRight size={16}/> كل المشاريع</Button><PermissionGuard allow={permissions.projects_edit}><Button variant="ghost" onClick={()=>setEditing((value)=>!value)}><Pencil size={15}/> تعديل البيانات</Button></PermissionGuard></>}/>
    <div className="workspace-statusbar"><LifecycleBadge value={project.lifecycle}/><StageBadge value={project.execution_stage || project.status}/><div className="workspace-progress"><span style={{width:`${Math.min(100,Math.max(0,number(effectiveProgress)))}%`}}/><b>{number(effectiveProgress).toFixed(0)}%</b></div><small>الوضع: {PROJECT_PROGRESS_MODES[project.progress_mode || "hybrid"]}</small></div>
    <ErrorState error={error}/><SuccessState message={success}/>

    {editing && <Panel className="workspace-editor"><h3>بيانات المشروع</h3><div className="v22-form-grid">
      <Field label="اسم المشروع"><Input value={details.project_name || ""} onChange={(e)=>setDetails({...details,project_name:e.target.value})}/></Field>
      <Field label="العميل"><Select value={details.customer_id || ""} onChange={(e)=>setDetails({...details,customer_id:e.target.value})}><option value="">بدون عميل</option>{data.customers.filter((row)=>!row.archived_at || row.id===details.customer_id).map((row)=><option key={row.id} value={row.id}>{row.name}{row.archived_at ? " (مؤرشف)" : ""}</option>)}</Select></Field>
      <Field label="الموقع"><Input value={details.location || ""} onChange={(e)=>setDetails({...details,location:e.target.value})}/></Field>
      <Field label="الأولوية"><Select value={details.priority || "normal"} onChange={(e)=>setDetails({...details,priority:e.target.value})}>{Object.entries(PROJECT_PRIORITIES).map(([key,label])=><option key={key} value={key}>{label}</option>)}</Select></Field>
      <Field label="تاريخ البدء"><Input type="date" value={details.start_date || ""} onChange={(e)=>setDetails({...details,start_date:e.target.value})}/></Field>
      <Field label="موعد التسليم"><Input type="date" value={details.delivery_date || ""} onChange={(e)=>setDetails({...details,delivery_date:e.target.value})}/></Field>
      <PermissionGuard allow={permissions.project_financials_view}><Field label="التكلفة المتوقعة"><Input type="number" min="0" value={details.expected_cost ?? 0} onChange={(e)=>setDetails({...details,expected_cost:e.target.value})}/></Field><Field label="الإيراد"><Input type="number" min="0" value={details.revenue ?? 0} onChange={(e)=>setDetails({...details,revenue:e.target.value})}/></Field></PermissionGuard>
      <Field label="ملاحظات" wide><TextArea value={details.notes || ""} onChange={(e)=>setDetails({...details,notes:e.target.value})}/></Field>
    </div><div className="v22-actions"><Button variant="ghost" onClick={()=>setEditing(false)}>إلغاء</Button><Button disabled={busy} onClick={saveDetails}>حفظ البيانات</Button></div></Panel>}

    <nav className="workspace-tabs" aria-label="أقسام مساحة المشروع">{TABS.map(([id,label,Icon])=><button key={id} className={tab===id?"active":""} onClick={()=>setTab(id)}><Icon size={15}/><span>{label}</span></button>)}</nav>

    {tab === "overview" && <div className="workspace-overview">
      <ProjectPilotWorkflow workflow={workflow} data={data} project={project} busy={busy} managerTarget={managerTarget} setManagerTarget={setManagerTarget} managerReason={managerReason} setManagerReason={setManagerReason} onAction={runWorkflowAction} onAssign={assignManager} onClose={closeProject} onBudget={()=>setTab("budget")}/>
      <div className="workspace-hero-grid"><Panel><h3>بطاقة المشروع</h3><dl className="workspace-facts"><div><dt>الكود</dt><dd>{project.project_code}</dd></div><div><dt>العميل</dt><dd>{customer?.name || "غير محدد"}</dd></div><div><dt>مدير المشروع</dt><dd>{manager?.full_name || manager?.email || "غير محدد"}</dd></div><div><dt>الأولوية</dt><dd>{PROJECT_PRIORITIES[project.priority || "normal"]}</dd></div><div><dt>البداية</dt><dd>{project.start_date || "غير محدد"}</dd></div><div><dt>التسليم</dt><dd>{project.delivery_date || "غير محدد"}</dd></div></dl></Panel>
      <Panel><h3>الإنجاز</h3><div className="progress-comparison"><div><span>الفعلي المعروض</span><strong>{number(effectiveProgress).toFixed(1)}%</strong></div><div><span>المحسوب من المراحل</span><strong>{number(project.calculated_progress_percentage ?? calculatedProgress).toFixed(1)}%</strong></div><div><span>اليدوي</span><strong>{number(project.manual_progress_percentage ?? project.progress_percentage).toFixed(1)}%</strong></div></div><p className="workspace-note">الإنجاز مادي وتشغيلي فقط؛ الإنفاق المالي لا يدخل في حسابه.</p></Panel></div>
      <div className="v22-grid cols-5 workspace-kpis"><StatCard label="العوائق" value={summary.blockers.length} tone={summary.blockers.length?"negative":"positive"}/><StatCard label="المراحل المتأخرة" value={summary.overdueMilestones.length} tone={summary.overdueMilestones.length?"negative":"normal"}/><StatCard label="العُهد المفتوحة" value={openAssignments}/><StatCard label="أوامر الإنتاج" value={summary.productionOrders.length}/><StatCard label={fifthKpi.label} value={fifthKpi.value}/></div>
      <details className="workspace-management"><summary>إدارة حالة المشروع والإنجاز</summary><div className="workspace-actions-grid"><PermissionGuard allow={permissions.projects_manage_lifecycle}><Panel><h3>دورة حياة المشروع</h3><div className="workspace-inline-form"><Select value={lifecycleTarget} onChange={(e)=>setLifecycleTarget(e.target.value)}><option value="">اختر الانتقال التالي</option>{nextLifecycles.map((next)=><option key={next} value={next}>{PROJECT_LIFECYCLES[next]}</option>)}</Select>{lifecycleTarget&&lifecycleNeedsReason(project.lifecycle,lifecycleTarget)&&<TextArea value={lifecycleReason} onChange={(e)=>setLifecycleReason(e.target.value)} placeholder="السبب الإجباري"/>}<Button disabled={busy||!lifecycleTarget} onClick={transitionLifecycle}>تنفيذ الانتقال</Button></div>{project.legacy_activation_exempt&&<small className="legacy-note">مشروع قديم: إعفاء التفعيل محفوظ وصريح، ولا يُطلب منه اعتماد ميزانية بأثر رجعي.</small>}</Panel></PermissionGuard>
      <PermissionGuard allow={permissions.projects_manage_milestones}><Panel><h3>مرحلة التنفيذ الحالية</h3><div className="workspace-inline-form"><Select value={stage} onChange={(e)=>setStage(e.target.value)}>{Object.entries(PROJECT_EXECUTION_STAGES).map(([key,label])=><option key={key} value={key}>{label}</option>)}</Select><Button disabled={busy} onClick={saveStage}>تحديث المرحلة</Button></div></Panel></PermissionGuard>
      <PermissionGuard allow={permissions.projects_update_progress}><Panel><h3>نموذج الإنجاز</h3><div className="workspace-inline-form"><Select value={progress.mode} onChange={(e)=>setProgress({...progress,mode:e.target.value})}>{Object.entries(PROJECT_PROGRESS_MODES).map(([key,label])=><option key={key} value={key}>{label}</option>)}</Select>{progress.mode!=="automatic"&&<Input type="number" min="0" max="100" value={progress.manual} onChange={(e)=>setProgress({...progress,manual:e.target.value})}/>} {progress.mode==="hybrid"&&<TextArea value={progress.reason} onChange={(e)=>setProgress({...progress,reason:e.target.value})} placeholder="سبب التجاوز عند اختلاف القيمة اليدوية"/>}<Button disabled={busy} onClick={saveProgress}>حفظ الإنجاز</Button></div></Panel></PermissionGuard></div></details>
       <Panel><h3>آخر النشاط</h3>{summary.activities.length?<ul className="workspace-simple-list">{[...summary.activities].sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)).slice(0,5).map((row)=><li key={row.id}><span>{row.description}</span><small>{new Date(row.created_at).toLocaleString("ar-EG")}</small></li>)}</ul>:<EmptyState title="لا يوجد نشاط بعد"/>}</Panel>
    </div>}

    {tab === "milestones" && <div className="workspace-section"><div className="workspace-section-head"><div><h3>مراحل التنفيذ</h3><p>أوزان المراحل النشطة لا تتجاوز 100%، والمراحل الملغاة لا تدخل في الحساب.</p></div><PermissionGuard allow={permissions.projects_manage_milestones}><Button onClick={()=>{setMilestone(emptyMilestone);setShowMilestoneForm(true);}}><Plus size={15}/> إضافة مرحلة</Button></PermissionGuard></div>
      {showMilestoneForm&&<Panel className="workspace-editor"><div className="v22-form-grid"><Field label="العنوان"><Input value={milestone.title} onChange={(e)=>setMilestone({...milestone,title:e.target.value})}/></Field><Field label="مفتاح المرحلة"><Select value={milestone.stage_key} onChange={(e)=>setMilestone({...milestone,stage_key:e.target.value})}>{Object.entries(PROJECT_EXECUTION_STAGES).map(([key,label])=><option key={key} value={key}>{label}</option>)}</Select></Field><Field label="الترتيب"><Input type="number" min="0" value={milestone.sequence} onChange={(e)=>setMilestone({...milestone,sequence:e.target.value})}/></Field><Field label="الوزن %"><Input type="number" min="0" max="100" value={milestone.weight_percentage} onChange={(e)=>setMilestone({...milestone,weight_percentage:e.target.value})}/></Field><Field label="المسؤول"><Select value={milestone.responsibleIdentity} onChange={(e)=>setMilestone({...milestone,responsibleIdentity:e.target.value})}><IdentityOptions data={data}/></Select></Field><Field label="الحالة"><Select value={milestone.status} onChange={(e)=>setMilestone({...milestone,status:e.target.value,progress_percentage:e.target.value==="completed"?100:e.target.value==="not_started"?0:milestone.progress_percentage})}>{Object.entries(MILESTONE_STATUSES).map(([key,label])=><option key={key} value={key}>{label}</option>)}</Select></Field><Field label="الإنجاز %"><Input type="number" min="0" max="100" value={milestone.progress_percentage} onChange={(e)=>setMilestone({...milestone,progress_percentage:e.target.value})}/></Field><Field label="بداية مخططة"><Input type="date" value={milestone.planned_start_date||""} onChange={(e)=>setMilestone({...milestone,planned_start_date:e.target.value})}/></Field><Field label="نهاية مخططة"><Input type="date" value={milestone.planned_end_date||""} onChange={(e)=>setMilestone({...milestone,planned_end_date:e.target.value})}/></Field>{milestone.status==="blocked"&&<Field label="سبب التعثر" wide><TextArea value={milestone.blocking_reason||""} onChange={(e)=>setMilestone({...milestone,blocking_reason:e.target.value})}/></Field>}<Field label="الوصف" wide><TextArea value={milestone.description||""} onChange={(e)=>setMilestone({...milestone,description:e.target.value})}/></Field></div><div className="v22-actions"><Button variant="ghost" onClick={()=>setShowMilestoneForm(false)}>إلغاء</Button><Button disabled={busy||!milestone.title.trim()} onClick={saveMilestone}>حفظ المرحلة</Button></div></Panel>}
      {summary.milestones.length?<div className="milestone-list">{[...summary.milestones].sort((a,b)=>a.sequence-b.sequence).map((row)=><Panel key={row.id} className={`milestone-card ${row.status}`}><div className="milestone-head"><div><small>{PROJECT_EXECUTION_STAGES[row.stage_key]||row.stage_key} · وزن {number(row.weight_percentage)}%</small><h4>{row.title}</h4></div><span>{MILESTONE_STATUSES[row.status]}</span></div><div className="workspace-progress"><span style={{width:`${number(row.progress_percentage)}%`}}/><b>{number(row.progress_percentage)}%</b></div><div className="milestone-meta"><span><CalendarDays size={14}/>{row.planned_start_date||"—"} ← {row.planned_end_date||"—"}</span><span><Users size={14}/>{identityLabel(data,row.responsible_profile_id,row.responsible_employee_id)}</span></div>{row.blocking_reason&&<p className="blocking-reason"><AlertTriangle size={14}/>{row.blocking_reason}</p>}<PermissionGuard allow={permissions.projects_manage_milestones}><div className="v22-actions"><Button variant="ghost" onClick={()=>editMilestone(row)}>تعديل</Button>{row.status!=="cancelled"&&<Button variant="danger" onClick={()=>cancelMilestone(row)}>إلغاء المرحلة</Button>}</div></PermissionGuard></Panel>)}</div>:<Panel><EmptyState title="لا توجد مراحل تنفيذ" description="أضف المراحل المناسبة لهذا المشروع فقط؛ القالب غير مفروض."/></Panel>}
    </div>}

    {tab === "team" && <div className="workspace-section"><div className="workspace-section-head"><div><h3>فريق المشروع</h3><p>العضوية تحدد رؤية المشروع ولا تمنح صلاحيات نظام عامة.</p></div><PermissionGuard allow={permissions.projects_manage_team}><Button onClick={()=>setShowMemberForm(true)}><Plus size={15}/> إضافة عضو</Button></PermissionGuard></div>{showMemberForm&&<Panel className="workspace-editor"><div className="v22-form-grid"><Field label="الهوية"><Select value={member.identity} onChange={(e)=>setMember({...member,identity:e.target.value})}><IdentityOptions data={data}/></Select></Field><Field label="دور المشروع"><Select value={member.project_role} onChange={(e)=>setMember({...member,project_role:e.target.value})}>{Object.entries(PROJECT_MEMBER_ROLES).filter(([key])=>key!=="project_manager").map(([key,label])=><option key={key} value={key}>{label}</option>)}</Select></Field><Field label="من"><Input type="date" value={member.start_date} onChange={(e)=>setMember({...member,start_date:e.target.value})}/></Field><Field label="حتى"><Input type="date" value={member.end_date} onChange={(e)=>setMember({...member,end_date:e.target.value})}/></Field></div><div className="v22-actions"><Button variant="ghost" onClick={()=>setShowMemberForm(false)}>إلغاء</Button><Button disabled={busy||!member.identity} onClick={addMember}>إضافة للفريق</Button></div></Panel>}{summary.members.length?<div className="team-grid">{summary.members.map((row)=><Panel key={row.id} className="team-card"><div className="team-avatar">{identityLabel(data,row.profile_id,row.employee_id).slice(0,1)}</div><div><strong>{identityLabel(data,row.profile_id,row.employee_id)}</strong><span>{PROJECT_MEMBER_ROLES[row.project_role]}</span><small>{row.start_date||"بداية مفتوحة"} — {row.end_date||"مستمر"}</small></div>{row.project_role!=="project_manager"&&<PermissionGuard allow={permissions.projects_manage_team}><Button variant="ghost" onClick={()=>removeMember(row)}>إزالة</Button></PermissionGuard>}</Panel>)}</div>:<Panel><EmptyState title="لم يُحدد فريق المشروع" description="عيّن مدير المشروع من مسار الاعتماد، وأضف بقية أعضاء التنفيذ هنا دون منحهم صلاحيات عامة تلقائيًا."/></Panel>}</div>}

    {tab === "files" && <FileUploader project={project} files={summary.files} permissions={permissions} profile={profile} refresh={refresh}/>} 
    {tab === "materials" && <ProjectMaterialsPurchasesTab project={project} data={data} canViewFinancials={permissions.project_financials_view}/>} 
    {tab === "production" && <LinkedRows title="أوامر الإنتاج" rows={summary.productionOrders} empty="لا توجد أوامر إنتاج مرتبطة" render={(row)=><><span>{data.products.find((p)=>p.id===row.product_id)?.name||"أمر إنتاج"}</span><small>{row.status||"—"} · {number(row.qty)} وحدة</small></>}/>} 
    {tab === "labor" && <div className="workspace-two-columns"><LinkedRows title="العمالة اليومية" rows={summary.labor} empty="لا توجد عمالة يومية مرتبطة" render={(row)=><><span>{row.worker_name}</span><small>{row.work_date} · {permissions.project_financials_view?money(row.total_amount):"التكلفة محجوبة"}</small></>}/><LinkedRows title="سجلات الرواتب المرتبطة حاليًا" rows={summary.payroll} empty="لا توجد سجلات رواتب مرتبطة" render={(row)=><><span>{data.employees.find((e)=>e.id===row.employee_id)?.full_name||"موظف"}</span><small>{row.payroll_month} · {permissions.project_financials_view?money(row.net_salary):"التكلفة محجوبة"}</small></>}/></div>}
    {tab === "expenses" && <ProjectExpensesTab rows={summary.expenses} canViewFinancials={permissions.project_financials_view} refresh={refresh}/>} 
    {tab === "assets" && <LinkedRows title="العُهد والأصول المرتبطة" rows={summary.assignments} empty="لا توجد عهد مفتوحة مرتبطة" render={(row)=><><span>{row.assignment_code||"عهدة"}</span><small>{row.status} · العهدة نفسها ليست تكلفة مشروع</small></>}/>} 
    {tab === "budget" && <ProjectBudgetTab project={project} data={data} permissions={permissions} refresh={refresh}/>}
    {tab === "actualCost" && <PermissionGuard allow={permissions.project_financials_view} fallback={<div className="workspace-no-permission"><ShieldCheck size={24}/>لا تملك صلاحية عرض ماليات المشروع.</div>}><ProjectActualCostTab project={project} profile={profile}/></PermissionGuard>}
    {tab === "activity" && <ProjectTimeline activities={summary.activities}/>} 
    <ConfirmDialog open={Boolean(actionDialog)} title={actionDialog?.type==="milestone"?"إلغاء مرحلة التنفيذ":actionDialog?.type==="member"?"إزالة عضو الفريق":"إغلاق المشروع"} description={actionDialog?.type==="milestone"?`ستُلغى مرحلة «${actionDialog?.row.title||"المرحلة"}» وتُستبعد من حساب الإنجاز مع بقاء تاريخها.`:actionDialog?.type==="member"?`ستُنهى عضوية ${actionDialog?.row?identityLabel(data,actionDialog.row.profile_id,actionDialog.row.employee_id):"العضو"} في هذا المشروع فقط، دون تغيير صلاحيات حسابه العامة.`:"سيصبح المشروع مغلقًا للعمليات الجديدة مع الحفاظ على كامل تاريخه المالي والتشغيلي."} confirmLabel={actionDialog?.type==="milestone"?"إلغاء المرحلة":actionDialog?.type==="member"?"إزالة العضو":"إغلاق المشروع"} danger busy={busy} reasonRequired={actionDialog?.type!=="member"} reason={actionDialog?.reason||""} onReasonChange={reason=>setActionDialog(current=>({...current,reason}))} onConfirm={confirmActionDialog} onCancel={()=>setActionDialog(null)}/>
  </div>;
}

function LinkedRows({ title, rows, empty, render }) {
  return <Panel><h3>{title}</h3>{rows.length?<ul className="workspace-simple-list">{rows.map((row)=><li key={row.id}>{render(row)}</li>)}</ul>:<EmptyState title={empty}/>}</Panel>;
}
