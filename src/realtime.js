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
});

export const TABLES = Object.freeze(
  Object.fromEntries(Object.entries(REALTIME_TABLE_TO_KEY).map(([table, key]) => [key, table]))
);

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
