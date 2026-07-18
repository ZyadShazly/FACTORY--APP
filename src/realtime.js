export const REALTIME_TABLE_TO_KEY = Object.freeze({
  profiles: "profiles",
  projects: "projects",
  project_files: "projectFiles",
  project_activities: "projectActivities",
  employees: "employees",
  payroll: "payroll",
  daily_labor: "dailyLabor",
  materials: "materials",
  material_purchases: "materialPurchases",
  products: "products",
  production_orders: "productionOrders",
  expenses: "expenses",
  sales: "sales",
  rentals: "rentals",
  suppliers: "suppliers",
  supplier_payments: "supplierPayments",
  customers: "customers",
  customer_receipts: "customerReceipts",
  project_costs: "projectCosts",
  audit_log: "auditLog",
  departments: "departments",
  work_schedules: "workSchedules",
  work_schedule_days: "workScheduleDays",
  holiday_calendar: "holidayCalendar",
  holiday_scopes: "holidayScopes",
  asset_categories: "assetCategories",
  asset_locations: "assetLocations",
  assets: "assets",
  asset_assignments: "assetAssignments",
  asset_assignment_items: "assetAssignmentItems",
  asset_return_events: "assetReturnEvents",
  asset_return_items: "assetReturnItems",
  asset_settlements: "assetSettlements",
  asset_movements: "assetMovements",
  asset_attachments: "assetAttachments",
});

export const TABLES = Object.freeze(
  { ...Object.fromEntries(Object.entries(REALTIME_TABLE_TO_KEY).map(([table, key]) => [key, table])), assetAlerts: "asset_alerts" }
);

const PRODUCTION_DATA_KEYS = Object.freeze(["materials", "products", "productionOrders"]);
const PRODUCTION_ASSET_KEYS = Object.freeze(["assetCategories", "assetLocations", "assets", "assetAssignments", "assetAssignmentItems", "assetReturnEvents", "assetReturnItems", "assetMovements", "assetAttachments", "assetAlerts"]);

export function dataTableKeysForRole(role, assetsAllowed = false) {
  return role === "production" ? [...PRODUCTION_DATA_KEYS, ...(assetsAllowed ? PRODUCTION_ASSET_KEYS : [])] : Object.keys(TABLES);
}

export function isActiveProfile(profile) {
  return Boolean(profile) && (!profile.status || profile.status === "active");
}

export function resolveAllowedTab(currentTab, allowedPages = []) {
  if (currentTab && allowedPages.includes(currentTab)) return currentTab;
  return allowedPages[0] || null;
}

export function combinedRealtimeStatus(channelStatuses) {
  const statuses = Object.values(channelStatuses);
  if (statuses.length && statuses.every((status) => status === "SUBSCRIBED")) return "CONNECTED";
  if (statuses.some((status) => status === "CHANNEL_ERROR" || status === "TIMED_OUT")) return "RECONNECTING";
  return "CONNECTING";
}
