export const NAV_BY_ROLE = {
  manager: ["dashboard", "projects", "projectFiles", "inventory", "purchases", "expenses", "materials", "products", "production", "sales", "rentals", "suppliers", "customers", "employees", "payroll", "dailyLabor", "reports", "auditLog", "team"],
  accountant: ["projects", "projectFiles", "inventory", "purchases", "expenses", "materials", "products", "production", "sales", "rentals", "suppliers", "customers", "employees", "payroll", "dailyLabor"],
  production: ["projects", "projectFiles", "inventory", "production"],
};

export const ALL_PAGE_IDS = [
  "dashboard", "projects", "projectFiles", "inventory", "purchases", "expenses", "materials", "products", "production", "assets", "sales", "rentals", "suppliers", "customers", "employees", "workCalendar", "payroll", "dailyLabor", "reports", "auditLog", "team", "settings",
];

export const PAGE_LABELS = {
  projects: "المشاريع",
  projectFiles: "ملفات المشاريع",
  employees: "الموظفون",
  workCalendar: "تقويم العمل والعطلات",
  payroll: "المرتبات",
  dailyLabor: "العمالة اليومية",
  auditLog: "سجل التدقيق",
  dashboard: "لوحة التحكم",
  inventory: "المخزون",
  purchases: "المشتريات",
  expenses: "المصروفات",
  materials: "المواد الخام",
  products: "المنتجات والتكلفة",
  production: "أوامر الإنتاج",
  assets: "الأصول والعِدّة",
  sales: "المبيعات",
  rentals: "الإيجارات",
  suppliers: "الموردين",
  customers: "العملاء",
  reports: "التقارير",
  team: "الفريق والصلاحيات",
  settings: "الإعدادات",
  assetAlerts: "تنبيهات الأصول",
};

export const PAGE_DESCRIPTIONS = {
  dashboard: "ملخص تنفيذي لأهم مؤشرات العمل والتنبيهات والأنشطة الحديثة.",
  projects: "متابعة المشاريع ونسب الإنجاز والعملاء والملفات المرتبطة.",
  projectFiles: "الوصول المنظم إلى مستندات المشاريع ومرفقاتها.",
  inventory: "رؤية فورية لأرصدة الخامات والمنتجات وحالات النقص.",
  purchases: "تسجيل ومراجعة مشتريات التشغيل وتكاليف التوريد.",
  expenses: "إدارة المصروفات وتصنيفها ومتابعة أثرها المالي.",
  materials: "تعريف الخامات ومتابعة التكلفة والرصيد المتاح.",
  products: "إدارة المنتجات ومكونات التصنيع والتكلفة التقديرية.",
  production: "تخطيط أوامر الإنتاج ومتابعة التنفيذ والكميات.",
  assets: "إدارة الأصول والعِدّة والعهد والإرجاعات وسجل الحركة.",
  sales: "تسجيل المبيعات ومتابعة حركة المنتجات والعملاء.",
  rentals: "إدارة عمليات الإيجار وحالة الوحدات المستأجرة.",
  suppliers: "متابعة الموردين والمستحقات والمدفوعات.",
  customers: "إدارة بيانات العملاء والأرصدة والتحصيلات.",
  employees: "إدارة فريق العمل والبيانات الوظيفية.",
  workCalendar: "إدارة أسبوع العمل والورديات والعطلات بإصدارات تاريخية قابلة للتدقيق.",
  payroll: "إعداد الرواتب ومراجعتها واعتماد دورة الصرف.",
  dailyLabor: "تسجيل العمالة اليومية والتكلفة والحضور.",
  reports: "تحليل الأداء المالي والتشغيلي لاتخاذ قرارات أوضح.",
  auditLog: "تتبع العمليات والتغييرات الحساسة داخل النظام.",
  team: "إدارة المستخدمين والأدوار والصلاحيات بأمان.",
  settings: "إعدادات الإدارة وأدوات الاسترداد الآمن للحسابات.",
};

export function pageLabel(pageId) {
  return PAGE_LABELS[pageId] || pageId;
}
