export const ACTION_PERMISSIONS = Object.freeze([
  "projects_view", "projects_create", "projects_edit", "projects_delete", "project_files_view",
  "project_files_upload", "project_files_delete", "project_financials_view",
  "projects_manage_lifecycle", "projects_manage_milestones", "projects_manage_team", "projects_update_progress", "projects_close", "projects_override",
  "project_budget_view", "project_budget_create", "project_budget_edit", "project_budget_submit", "project_budget_approve",
  "project_budget_reject", "project_budget_view_financials", "project_budget_manage_templates", "project_budget_override_activation",
  "payroll_view", "payroll_create", "payroll_edit", "payroll_approve", "payroll_bonus_manage", "payroll_mark_paid",
  "payroll_calendar_view", "payroll_calendar_manage", "payroll_calendar_approve", "payroll_calendar_stale_override",
  "daily_labor_view", "daily_labor_create", "daily_labor_edit", "daily_labor_delete", "daily_labor_pay", "audit_log_view",
  "assets_view", "assets_manage", "assets_issue", "assets_receive", "assets_return", "assets_adjust", "assets_approve_loss", "assets_reports",
  "accounting_view", "accounting_accounts_manage", "accounting_journal_create", "accounting_journal_post",
  "accounting_journal_reverse", "accounting_journal_edit_posted", "accounting_reports_view", "accounting_settings_manage", "accounting_period_manage",
]);

const ACCOUNTANT_DEFAULTS = Object.freeze([
  "projects_view", "projects_create", "project_financials_view", "project_files_view", "project_files_upload",
  "project_budget_view", "project_budget_create", "project_budget_edit", "project_budget_submit", "project_budget_reject", "project_budget_view_financials",
  "payroll_view", "payroll_create", "payroll_edit", "payroll_mark_paid", "daily_labor_view",
  "daily_labor_create", "daily_labor_edit", "daily_labor_pay",
  "accounting_view", "accounting_accounts_manage", "accounting_journal_create", "accounting_journal_post", "accounting_journal_reverse", "accounting_reports_view",
]);

export function actionPermissions(profile) {
  if (profile?.role === "owner") {
    return Object.fromEntries(ACTION_PERMISSIONS.map((key) => [key, true]));
  }

  if (profile?.role === "manager") {
    const resolved = Object.fromEntries(ACTION_PERMISSIONS.map((key) => [key, true]));
    for (const key of ["project_budget_approve", "project_budget_reject"]) {
      resolved[key] = profile?.permissions?.[key] === true;
    }
    resolved.project_budget_override_activation = false;
    for (const key of ACTION_PERMISSIONS.filter((permission) => permission.startsWith("accounting_"))) {
      resolved[key] = profile?.permissions?.[key] === true;
    }
    resolved.accounting_journal_edit_posted = false;
    resolved.accounting_settings_manage = false;
    resolved.accounting_period_manage = false;
    return resolved;
  }

  const defaults = profile?.role === "accountant" ? ACCOUNTANT_DEFAULTS : [];
  const saved = profile?.permissions || {};
  const resolved = Object.fromEntries(
    ACTION_PERMISSIONS.map((key) => [key, saved[key] ?? defaults.includes(key)]),
  );

  resolved.audit_log_view = false;
  resolved.accounting_journal_edit_posted = false;
  resolved.accounting_settings_manage = false;
  resolved.accounting_period_manage = false;

  if (profile?.role === "production") {
    for (const key of ACTION_PERMISSIONS.filter((permission) => permission.startsWith("accounting_"))) {
      resolved[key] = false;
    }
    for (const key of ACTION_PERMISSIONS.filter((permission) => permission.startsWith("payroll_calendar_"))) {
      resolved[key] = false;
    }
    for (const key of ACTION_PERMISSIONS.filter((permission) => permission.startsWith("assets_") && !["assets_view", "assets_issue", "assets_return"].includes(permission))) {
      resolved[key] = false;
    }
    for (const key of ACTION_PERMISSIONS.filter((permission) => permission.startsWith("project") && ![
      "projects_view", "project_files_view", "project_files_upload", "projects_manage_milestones",
      "projects_update_progress", "project_budget_view", "project_budget_view_financials",
    ].includes(permission))) {
      resolved[key] = false;
    }
    resolved.projects_view = true;
    resolved.project_files_view = true;
  }

  return resolved;
}
