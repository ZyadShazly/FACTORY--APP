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
  { id: "dashboard", label: "لوحة التحكم", icon: LayoutDashboard, description: "ملخص تنفيذي لأهم مؤشرات العمل والتنبيهات والأنشطة الحديثة." },
  { id: "projects", label: "المشاريع", icon: BriefcaseBusiness, description: "متابعة المشاريع ونسب الإنجاز والعملاء والملفات المرتبطة." },
  { id: "projectFiles", label: "ملفات المشاريع", icon: FolderOpen, description: "الوصول المنظم إلى مستندات المشاريع ومرفقاتها." },
  { id: "inventory", label: "المخزون", icon: Boxes, description: "رؤية فورية لأرصدة الخامات والمنتجات وحالات النقص." },
  { id: "purchases", label: "المشتريات", icon: ClipboardList, description: "تسجيل ومراجعة مشتريات التشغيل وتكاليف التوريد." },
  { id: "expenses", label: "المصروفات", icon: ReceiptText, description: "إدارة المصروفات وتصنيفها ومتابعة أثرها المالي." },
  { id: "materials", label: "المواد الخام", icon: Package, description: "تعريف الخامات ومتابعة التكلفة والرصيد المتاح." },
  { id: "products", label: "المنتجات والتكلفة", icon: Layers, description: "إدارة المنتجات ومكونات التصنيع والتكلفة التقديرية." },
  { id: "production", label: "أوامر الإنتاج", icon: Factory, description: "تخطيط أوامر الإنتاج ومتابعة التنفيذ والكميات." },
  { id: "assets", label: "الأصول والعِدّة", icon: Wrench, description: "إدارة الأصول والعِدّة والعهد والإرجاعات وسجل الحركة." },
  { id: "sales", label: "المبيعات", icon: ShoppingCart, description: "تسجيل المبيعات ومتابعة حركة المنتجات والعملاء." },
  { id: "rentals", label: "الإيجارات", icon: CalendarClock, description: "إدارة عمليات الإيجار وحالة الوحدات المستأجرة." },
  { id: "suppliers", label: "الموردين", icon: Truck, description: "متابعة الموردين والمستحقات والمدفوعات." },
  { id: "customers", label: "العملاء", icon: Users, description: "إدارة بيانات العملاء والأرصدة والتحصيلات." },
  { id: "employees", label: "الموظفون", icon: UserRoundCog, description: "إدارة فريق العمل والبيانات الوظيفية." },
  { id: "workCalendar", label: "تقويم العمل والعطلات", icon: CalendarClock, description: "إدارة أسبوع العمل والورديات والعطلات بإصدارات تاريخية قابلة للتدقيق." },
  { id: "payroll", label: "المرتبات", icon: BadgeDollarSign, description: "إعداد الرواتب ومراجعتها واعتماد دورة الصرف." },
  { id: "dailyLabor", label: "العمالة اليومية", icon: HardHat, description: "تسجيل العمالة اليومية والتكلفة والحضور." },
  { id: "reports", label: "التقارير", icon: BarChart3, description: "تحليل الأداء المالي والتشغيلي لاتخاذ قرارات أوضح." },
  { id: "auditLog", label: "سجل التدقيق", icon: ScrollText, description: "تتبع العمليات والتغييرات الحساسة داخل النظام." },
  { id: "team", label: "الفريق والصلاحيات", icon: ShieldCheck, description: "إدارة المستخدمين والأدوار والصلاحيات بأمان." },
  { id: "settings", label: "الإعدادات", icon: Settings, description: "إعدادات الإدارة وأدوات الاسترداد الآمن للحسابات." },
]);

export const APP_TAB_IDS = Object.freeze(APP_TABS.map((tab) => tab.id));
export const APP_TAB_LABELS = Object.freeze(
  Object.fromEntries(APP_TABS.map((tab) => [tab.id, tab.label])),
);
export const APP_TAB_DESCRIPTIONS = Object.freeze(
  Object.fromEntries(APP_TABS.map((tab) => [tab.id, tab.description])),
);
export const APP_PAGE_LABELS = Object.freeze({
  ...APP_TAB_LABELS,
  assetAlerts: "تنبيهات الأصول",
});

export const DEFAULT_TABS_BY_ROLE = Object.freeze({
  manager: Object.freeze(["dashboard", "projects", "projectFiles", "inventory", "purchases", "expenses", "materials", "products", "production", "sales", "rentals", "suppliers", "customers", "employees", "payroll", "dailyLabor", "reports", "auditLog", "team"]),
  accountant: Object.freeze(["projects", "projectFiles", "inventory", "purchases", "expenses", "materials", "products", "production", "sales", "rentals", "suppliers", "customers", "employees", "payroll", "dailyLabor"]),
  production: Object.freeze(["projects", "projectFiles", "inventory", "production"]),
});

export function visibleTabs(allowedPageIds = []) {
  const allowed = new Set(allowedPageIds);
  return APP_TABS.filter((tab) => allowed.has(tab.id));
}

export function findTab(tabId) {
  return APP_TABS.find((tab) => tab.id === tabId) || null;
}
