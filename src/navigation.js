export const NAV_GROUPS = [
  { id: "home", label: "الرئيسية", pages: ["dashboard"] },
  { id: "projects", label: "إدارة المشاريع", pages: ["projects", "projectFiles"] },
  { id: "operations", label: "التشغيل والإنتاج", pages: ["inventory", "materials", "products", "production", "assets"] },
  { id: "finance", label: "المالية", pages: ["purchases", "expenses", "sales", "rentals", "suppliers", "customers"] },
  { id: "hr", label: "الموارد البشرية", pages: ["employees", "workCalendar", "payroll", "dailyLabor"] },
  { id: "analytics", label: "التقارير والتحليلات", pages: ["reports"] },
  { id: "admin", label: "الإدارة", pages: ["auditLog", "team", "settings"] },
];

export const NAV_GROUP_STORAGE_KEY = "nextep.sidebar.groups.v2";

export function buildNavigationGroups(navigationItems, allowedPages) {
  const allowed = new Set(allowedPages || []);
  const byId = new Map(navigationItems.map((item) => [item.id, item]));

  return NAV_GROUPS.map((group) => ({
    ...group,
    items: group.pages
      .filter((pageId) => allowed.has(pageId))
      .map((pageId) => byId.get(pageId))
      .filter(Boolean),
  })).filter((group) => group.items.length > 0);
}

export function loadNavigationState(storage = globalThis.localStorage) {
  const defaults = Object.fromEntries(NAV_GROUPS.map((group) => [group.id, group.id === "home"]));
  if (!storage) return defaults;
  try {
    return { ...defaults, ...JSON.parse(storage.getItem(NAV_GROUP_STORAGE_KEY) || "{}") };
  } catch {
    return defaults;
  }
}
