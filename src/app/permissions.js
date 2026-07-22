import { actionPermissions } from "./actionPermissions.js";
import { isAdministrativeRole, PRODUCTION_ALLOWED_PAGES } from "../identity.js";
import { APP_TAB_IDS, DEFAULT_TABS_BY_ROLE } from "./navigationRegistry.js";

export function permissionsForProfile(profile) {
  const actions = actionPermissions(profile);

  if (isAdministrativeRole(profile?.role)) {
    return {
      pages: APP_TAB_IDS,
      can_delete: true,
      view_financials: true,
      can_create_products: true,
      can_edit_products: true,
      ...actions,
    };
  }

  if (profile?.role === "production") {
    const hasSavedPages = Array.isArray(profile?.permissions?.pages);
    const savedPages = hasSavedPages
      ? profile.permissions.pages.filter((page) => PRODUCTION_ALLOWED_PAGES.includes(page))
      : ["projects", "production"];

    return {
      pages: [...new Set(["projects", ...savedPages])],
      can_delete: false,
      view_financials: false,
      can_create_products: false,
      can_edit_products: false,
      ...actions,
    };
  }

  const saved = profile?.permissions || {};
  const isAccountant = profile?.role === "accountant";
  const legacyPages = (
    Array.isArray(saved.pages)
      ? saved.pages
      : (DEFAULT_TABS_BY_ROLE[profile?.role] || [])
  ).filter((page) => page !== "settings");

  const modulePages = [
    actions.projects_view && "projects",
    actions.project_files_view && "projectFiles",
    actions.assets_view && "assets",
    actions.payroll_calendar_view && "workCalendar",
    actions.payroll_view && "payroll",
    actions.daily_labor_view && "dailyLabor",
  ].filter(Boolean);

  if (actions.audit_log_view) modulePages.push("auditLog");

  return {
    pages: [...new Set([...legacyPages, ...modulePages])],
    can_delete: Boolean(saved.can_delete),
    view_financials: Boolean(saved.view_financials),
    can_create_products: saved.can_create_products ?? isAccountant,
    can_edit_products: Boolean(saved.can_edit_products),
    ...actions,
  };
}
