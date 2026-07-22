import {
  BadgeDollarSign,
  BarChart3,
  Boxes,
  BriefcaseBusiness,
  CalendarClock,
  ClipboardList,
  Factory,
  FolderOpen,
  HardHat,
  Layers,
  LayoutDashboard,
  Package,
  ReceiptText,
  ScrollText,
  Settings,
  ShieldCheck,
  ShoppingCart,
  Truck,
  UserRoundCog,
  Users,
  Wrench,
} from "lucide-react";

export const APP_TABS = Object.freeze([
  { id: "dashboard", label: "لوحة التحكم", icon: LayoutDashboard },
  { id: "projects", label: "المشاريع", icon: BriefcaseBusiness },
  { id: "projectFiles", label: "ملفات المشاريع", icon: FolderOpen },
  { id: "inventory", label: "المخزون", icon: Boxes },
  { id: "purchases", label: "المشتريات", icon: ClipboardList },
  { id: "expenses", label: "المصروفات", icon: ReceiptText },
  { id: "materials", label: "المواد الخام", icon: Package },
  { id: "products", label: "المنتجات والتكلفة", icon: Layers },
  { id: "production", label: "أوامر الإنتاج", icon: Factory },
  { id: "assets", label: "الأصول والعِدّة", icon: Wrench },
  { id: "sales", label: "المبيعات", icon: ShoppingCart },
  { id: "rentals", label: "الإيجارات", icon: CalendarClock },
  { id: "suppliers", label: "الموردين", icon: Truck },
  { id: "customers", label: "العملاء", icon: Users },
  { id: "employees", label: "الموظفون", icon: UserRoundCog },
  { id: "workCalendar", label: "تقويم العمل والعطلات", icon: CalendarClock },
  { id: "payroll", label: "المرتبات", icon: BadgeDollarSign },
  { id: "dailyLabor", label: "العمالة اليومية", icon: HardHat },
  { id: "reports", label: "التقارير", icon: BarChart3 },
  { id: "auditLog", label: "سجل التدقيق", icon: ScrollText },
  { id: "team", label: "الفريق والصلاحيات", icon: ShieldCheck },
  { id: "settings", label: "الإعدادات", icon: Settings },
]);

export const APP_TAB_IDS = Object.freeze(APP_TABS.map((tab) => tab.id));
export const APP_TAB_LABELS = Object.freeze(
  Object.fromEntries(APP_TABS.map((tab) => [tab.id, tab.label])),
);

export function visibleTabs(allowedPageIds = []) {
  const allowed = new Set(allowedPageIds);
  return APP_TABS.filter((tab) => allowed.has(tab.id));
}

export function findTab(tabId) {
  return APP_TABS.find((tab) => tab.id === tabId) || null;
}
