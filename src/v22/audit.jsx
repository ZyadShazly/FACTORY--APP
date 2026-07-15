import React, { useMemo, useState } from "react";
import { DataTable, EmptyState, Input, PageTitle, Panel, Select } from "./shared";
import { auditActorLabel } from "./auditIdentity";

const TABLE_LABELS = {
  profiles:"المستخدمون", suppliers:"الموردون", customers:"العملاء", materials:"المواد الخام",
  material_purchases:"المشتريات", products:"المنتجات", production_orders:"أوامر الإنتاج",
  sales:"المبيعات", rentals:"الإيجارات", supplier_payments:"دفعات الموردين",
  customer_receipts:"تحصيلات العملاء", expenses:"المصروفات", projects:"المشاريع",
  project_files:"ملفات المشاريع", project_activities:"أنشطة المشاريع", employees:"الموظفون",
  payroll:"الرواتب", daily_labor:"العمالة اليومية", project_costs:"تكاليف المشاريع",
};
const ACTION_LABELS = { insert:"إضافة", update:"تعديل", delete:"حذف" };
export const PERMISSION_LABELS = {
  projects_view:"عرض المشاريع",projects_create:"إنشاء المشاريع",projects_edit:"تعديل المشاريع",projects_delete:"حذف المشاريع",
  project_files_view:"عرض ملفات المشاريع",project_files_upload:"رفع ملفات المشاريع",project_files_delete:"حذف ملفات المشاريع",
  project_financials_view:"عرض ماليات المشاريع",payroll_view:"عرض الرواتب",payroll_create:"إنشاء الرواتب",payroll_edit:"تعديل الرواتب",
  payroll_approve:"اعتماد الرواتب",payroll_bonus_manage:"إدارة المكافآت",payroll_mark_paid:"صرف الرواتب",
  daily_labor_view:"عرض العمالة اليومية",daily_labor_create:"إضافة ورديات",daily_labor_edit:"تعديل الورديات",
  daily_labor_delete:"حذف الورديات",daily_labor_pay:"دفع العمالة",audit_log_view:"عرض سجل التدقيق",
};

export function AuditLogTab({ data }) {
  const [table,setTable]=useState("");const[action,setAction]=useState("");const[search,setSearch]=useState("");
  const rows=useMemo(()=>data.auditLog.filter((r)=>(!table||r.table_name===table)&&(!action||r.action===action)&&(!search||`${r.record_id} ${auditActorLabel(r)} ${JSON.stringify(r.new_data||{})}`.toLowerCase().includes(search.toLowerCase()))).sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)),[data.auditLog,table,action,search]);
  return <div><PageTitle eyebrow="الحوكمة والأمان" title="سجل التدقيق" description="سجل غير قابل للتعديل لكل الإضافات والتغييرات والحذف وعمليات الدفع."/><Panel><div className="v22-filters"><Input value={search} onChange={(e)=>setSearch(e.target.value)} placeholder="بحث بالمعرف أو المستخدم أو البيانات..."/><Select value={table} onChange={(e)=>setTable(e.target.value)}><option value="">كل الوحدات</option>{Object.entries(TABLE_LABELS).map(([k,v])=><option key={k} value={k}>{v}</option>)}</Select><Select value={action} onChange={(e)=>setAction(e.target.value)}><option value="">كل الإجراءات</option>{Object.entries(ACTION_LABELS).map(([k,v])=><option key={k} value={k}>{v}</option>)}</Select></div>{rows.length?<DataTable headers={["الوقت","الوحدة","الإجراء","السجل","المستخدم","ملخص التغيير"]}>{rows.map((r)=>{const actorLabel=auditActorLabel(r);return <tr key={r.id}><td>{new Date(r.created_at).toLocaleString("ar-EG")}</td><td>{TABLE_LABELS[r.table_name]||r.table_name}</td><td><span className={`audit-action ${r.action}`}>{ACTION_LABELS[r.action]||r.action}</span></td><td><code>{r.record_id?.slice(0,12)}</code></td><td>{actorLabel===r.actor_id?<code>{actorLabel}</code>:actorLabel}</td><td className="audit-summary">{summarize(r)}</td></tr>})}</DataTable>:<EmptyState title="لا توجد أحداث مطابقة"/>}</Panel></div>;
}
function summarize(row){if(row.action==="delete")return"تم حذف السجل";const before=row.old_data||{};const after=row.new_data||{};const changed=Object.keys(after).filter((key)=>JSON.stringify(before[key])!==JSON.stringify(after[key])&&!['updated_at'].includes(key));return changed.slice(0,4).map((key)=>`${key}: ${String(after[key]??"—").slice(0,28)}`).join(" · ")||"تم إنشاء السجل"}
