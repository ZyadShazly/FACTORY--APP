import React from "react";
import { AlertCircle, CheckCircle2, Loader2, X } from "lucide-react";

export const theme = {
  bg: "var(--color-app-bg)", panel: "var(--color-surface)", panelAlt: "var(--color-surface-muted)", border: "var(--color-border)",
  wood: "var(--color-wood)", woodDark: "var(--color-wood-dark)", brass: "var(--color-gold)", text: "var(--color-text)",
  muted: "var(--color-text-muted)", green: "var(--color-success)", red: "var(--color-danger)", blue: "var(--color-info)",
};

export const money = (value) => `${Number(value || 0).toLocaleString("ar-EG", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} ج.م`;
export const number = (value) => Number.isFinite(Number(value)) ? Number(value) : 0;
export const today = () => new Date().toISOString().slice(0, 10);

export const ACTION_PERMISSIONS = [
  "projects_view", "projects_create", "projects_edit", "projects_delete", "project_files_view",
  "project_files_upload", "project_files_delete", "project_financials_view",
  "projects_manage_lifecycle", "projects_manage_milestones", "projects_manage_team", "projects_update_progress", "projects_close", "projects_override",
  "project_budget_view", "project_budget_create", "project_budget_edit", "project_budget_submit", "project_budget_approve",
  "project_budget_reject", "project_budget_view_financials", "project_budget_manage_templates", "project_budget_override_activation",
  "payroll_view",
  "payroll_create", "payroll_edit", "payroll_approve", "payroll_bonus_manage", "payroll_mark_paid",
  "payroll_calendar_view", "payroll_calendar_manage", "payroll_calendar_approve", "payroll_calendar_stale_override",
  "daily_labor_view", "daily_labor_create", "daily_labor_edit", "daily_labor_delete",
  "daily_labor_pay", "audit_log_view",
  "assets_view", "assets_manage", "assets_issue", "assets_receive", "assets_return", "assets_adjust", "assets_approve_loss", "assets_reports",
];

const ACCOUNTANT_DEFAULTS = [
  "projects_view", "projects_create", "project_financials_view", "project_files_view", "project_files_upload",
  "project_budget_view", "project_budget_create", "project_budget_edit", "project_budget_submit", "project_budget_reject", "project_budget_view_financials",
  "payroll_view", "payroll_create", "payroll_edit", "payroll_mark_paid", "daily_labor_view",
  "daily_labor_create", "daily_labor_edit", "daily_labor_pay",
];
const PRODUCTION_DEFAULTS = [];

export function actionPermissions(profile) {
  if (profile?.role === "owner") return Object.fromEntries(ACTION_PERMISSIONS.map((key) => [key, true]));
  if (profile?.role === "manager") {
    const resolved = Object.fromEntries(ACTION_PERMISSIONS.map((key) => [key, true]));
    for (const key of ["project_budget_approve","project_budget_reject"]) resolved[key] = profile?.permissions?.[key] === true;
    resolved.project_budget_override_activation = false;
    return resolved;
  }
  const defaults = profile?.role === "accountant" ? ACCOUNTANT_DEFAULTS : PRODUCTION_DEFAULTS;
  const saved = profile?.permissions || {};
  const resolved = Object.fromEntries(ACTION_PERMISSIONS.map((key) => [key, saved[key] ?? defaults.includes(key)]));
  resolved.audit_log_view = false;
  if (profile?.role === "production") {
    for (const key of ACTION_PERMISSIONS.filter((permission) => permission.startsWith("payroll_calendar_"))) resolved[key] = false;
    for (const key of ACTION_PERMISSIONS.filter((permission) => permission.startsWith("assets_") && !["assets_view", "assets_issue", "assets_return"].includes(permission))) resolved[key] = false;
    for (const key of ACTION_PERMISSIONS.filter((permission) => permission.startsWith("project") && !["projects_view", "project_files_view", "project_files_upload", "projects_manage_milestones", "projects_update_progress", "project_budget_view", "project_budget_view_financials"].includes(permission))) resolved[key] = false;
    resolved.projects_view = true;
    resolved.project_files_view = true;
  }
  return resolved;
}

export function PermissionGuard({ allow, children, fallback = null }) {
  return allow ? children : fallback;
}

export function Panel({ children, className = "", ...props }) {
  return <section className={`v22-panel ${className}`} {...props}>{children}</section>;
}

export function PageTitle({ eyebrow, title, description, actions, search, filters }) {
  return <header className="v22-page-title">
    <div><div className="v22-eyebrow">{eyebrow}</div><h2>{title}</h2>{description && <p>{description}</p>}</div>
    {(search || filters || actions) && <div className="v22-actions">{search}{filters}{actions}</div>}
  </header>;
}

export function Field({ label, children, wide = false }) {
  return <label className={`v22-field ${wide ? "wide" : ""}`}><span>{label}</span>{children}</label>;
}
export function Input(props) { return <input {...props} className={`v22-input ${props.className || ""}`} />; }
export function Select({ children, ...props }) { return <select {...props} className={`v22-input ${props.className || ""}`}>{children}</select>; }
export function TextArea(props) { return <textarea {...props} className={`v22-input v22-textarea ${props.className || ""}`} />; }
export function Button({ children, variant = "primary", ...props }) {
  return <button {...props} className={`v22-button ${variant}`}>{children}</button>;
}

export function EmptyState({ title = "لا توجد بيانات", description = "أضف أول سجل للبدء." }) {
  return <div className="v22-state"><div className="v22-state-icon">＋</div><strong>{title}</strong><span>{description}</span></div>;
}
export function LoadingState({ text = "جارِ التحميل..." }) {
  return <div className="v22-state"><Loader2 className="spin" size={25} /><span>{text}</span></div>;
}
export function ErrorState({ error }) {
  return error ? <div className="v22-alert error"><AlertCircle size={17} />{error}</div> : null;
}
export function SuccessState({ message }) {
  return message ? <div className="v22-alert success"><CheckCircle2 size={17} />{message}</div> : null;
}

export function Toast({ type = "success", message, onDismiss }) {
  if (!message) return null;
  const Icon = type === "error" ? AlertCircle : CheckCircle2;
  return <div className={`v22-toast ${type}`} role={type === "error" ? "alert" : "status"}>
    <Icon size={19} /><span>{message}</span>
    <button type="button" onClick={onDismiss} aria-label="إغلاق الرسالة"><X size={16} /></button>
  </div>;
}

export function ConfirmDialog({ open, title, description, confirmLabel = "تأكيد", danger = false, onConfirm, onCancel }) {
  if (!open) return null;
  return <div className="v22-modal-backdrop" role="presentation" onMouseDown={onCancel}>
    <div className="v22-modal" role="dialog" aria-modal="true" aria-labelledby="confirm-title" onMouseDown={(e) => e.stopPropagation()}>
      <button className="v22-icon-button close" onClick={onCancel} aria-label="إغلاق"><X size={18} /></button>
      <h3 id="confirm-title">{title}</h3><p>{description}</p>
      <div className="v22-actions"><Button variant="ghost" onClick={onCancel}>إلغاء</Button><Button variant={danger ? "danger" : "primary"} onClick={onConfirm}>{confirmLabel}</Button></div>
    </div>
  </div>;
}

export function StatCard({ label, value, hint, tone = "normal" }) {
  return <Panel className={`v22-stat ${tone}`}><span>{label}</span><strong>{value}</strong>{hint && <small>{hint}</small>}</Panel>;
}

export function DataTable({ headers, children }) {
  return <div className="v22-table-wrap"><table className="v22-table"><thead><tr>{headers.map((h) => <th key={h}>{h}</th>)}</tr></thead><tbody>{children}</tbody></table></div>;
}
