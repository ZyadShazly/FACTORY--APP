import { supabase } from "../supabaseClient";
import { downloadExcelWorkbook } from "./excelWorkbook";

const num = (value) => Number(value || 0);
const sum = (rows, key) => rows.reduce((total, row) => total + num(row[key]), 0);
const statusLabel = (value) => ({ draft: "مسودة", rejected: "مرفوض", approved: "معتمد", paid: "مدفوع", pending: "قيد المراجعة", unpaid: "غير مدفوع", partial: "مدفوع جزئيًا", active: "نشط", archived: "مؤرشف" }[value] || value || "—");
const dateOnly = (value) => value ? String(value).slice(0, 10) : "";

async function generatedBy() {
  const { data: auth } = await supabase.auth.getUser();
  const user = auth?.user;
  if (!user) return "مستخدم النظام";
  const { data: profile } = await supabase.from("profiles").select("full_name,email").eq("id", user.id).maybeSingle();
  return profile?.full_name || profile?.email || user.email || "مستخدم النظام";
}

function meta(reportTitle, filters, actor) {
  return {
    company: "NextEP ERP",
    reportTitle,
    generatedBy: actor,
    generatedAt: new Date().toISOString(),
    filters,
  };
}

function download(name, title, filters, actor, sheets) {
  const stamp = new Date().toISOString().slice(0, 10);
  downloadExcelWorkbook({ filename: `${name}-${stamp}.xls`, meta: meta(title, filters, actor), sheets });
}

export async function exportPayrollWorkbook({ dateFrom, dateTo }) {
  const actor = await generatedBy();
  const { data, error } = await supabase
    .from("payroll")
    .select("*,employee:employees(full_name,department,job_title)")
    .gte("payroll_month", dateFrom)
    .lte("payroll_month", dateTo)
    .order("payroll_month", { ascending: true });
  if (error) throw error;
  const rows = data || [];
  const filters = { "من": dateFrom, "إلى": dateTo };
  download("payroll-report", "تقرير مراجعة الرواتب", filters, actor, [
    {
      name: "الملخص",
      summary: [
        { label: "عدد الموظفين", value: new Set(rows.map((r) => r.employee_id)).size, type: "number" },
        { label: "إجمالي الأساسي", value: sum(rows, "base_salary"), type: "currency" },
        { label: "إجمالي البدلات", value: rows.reduce((t, r) => t + num(r.housing_allowance) + num(r.transport_allowance) + num(r.other_allowance), 0), type: "currency" },
        { label: "إجمالي الإضافي", value: sum(rows, "overtime_amount"), type: "currency" },
        { label: "إجمالي الخصومات", value: sum(rows, "deductions"), type: "currency" },
        { label: "إجمالي السلف", value: sum(rows, "advances"), type: "currency" },
        { label: "إجمالي المكافآت", value: sum(rows, "bonuses"), type: "currency" },
        { label: "صافي الرواتب", value: sum(rows, "net_salary"), type: "currency" },
      ],
      columns: [
        { label: "الحالة", key: "status", width: 90, type: "status", value: (r) => statusLabel(r.status) },
        { label: "عدد المسيرات", key: "count", width: 90, type: "number", value: (_, i) => i === 0 ? rows.length : "" },
      ],
      rows: rows.length ? [{ status: "جاهز للمراجعة" }] : [],
    },
    {
      name: "الموظفون",
      columns: [
        { label: "الموظف", width: 150, value: (r) => r.employee?.full_name || "موظف غير متاح" },
        { label: "القسم", width: 110, value: (r) => r.employee?.department || "—" },
        { label: "المسمى", width: 120, value: (r) => r.employee?.job_title || "—" },
        { label: "الشهر", key: "payroll_month", type: "date", width: 90 },
        { label: "الأساسي", key: "base_salary", type: "currency", width: 90 },
        { label: "بدل السكن", key: "housing_allowance", type: "currency", width: 90 },
        { label: "بدل النقل", key: "transport_allowance", type: "currency", width: 90 },
        { label: "بدلات أخرى", key: "other_allowance", type: "currency", width: 90 },
        { label: "الإضافي", key: "overtime_amount", type: "currency", width: 90 },
        { label: "الخصومات", key: "deductions", type: "currency", width: 90 },
        { label: "السلف", key: "advances", type: "currency", width: 90 },
        { label: "المكافآت", key: "bonuses", type: "currency", width: 90 },
        { label: "الصافي", key: "net_salary", type: "currency", width: 100 },
        { label: "الحالة", key: "status", type: "status", width: 85, value: (r) => statusLabel(r.status) },
      ],
      rows,
    },
    {
      name: "الخصومات والسلف",
      columns: [
        { label: "الموظف", width: 150, value: (r) => r.employee?.full_name || "—" },
        { label: "الشهر", key: "payroll_month", type: "date", width: 90 },
        { label: "الخصم", key: "deductions", type: "currency", width: 90 },
        { label: "سبب الخصم", key: "deduction_reason", width: 220 },
        { label: "السلفة/القسط", key: "advances", type: "currency", width: 100 },
        { label: "تفاصيل السلفة", key: "advance_reason", width: 220 },
        { label: "المكافأة", key: "bonuses", type: "currency", width: 90 },
        { label: "سبب المكافأة", key: "bonus_reason", width: 180 },
        { label: "سبب الرفض", key: "rejection_reason", width: 180 },
        { label: "ملاحظات", key: "notes", width: 220 },
      ],
      rows: rows.filter((r) => num(r.deductions) || num(r.advances) || num(r.bonuses) || r.rejection_reason || r.notes),
    },
    {
      name: "الموافقات",
      columns: [
        { label: "الموظف", width: 150, value: (r) => r.employee?.full_name || "—" },
        { label: "الشهر", key: "payroll_month", type: "date", width: 90 },
        { label: "الحالة", type: "status", width: 90, value: (r) => statusLabel(r.status) },
        { label: "تاريخ الاعتماد", key: "approved_at", type: "date", width: 110 },
        { label: "تاريخ الرفض", key: "rejected_at", type: "date", width: 110 },
        { label: "تاريخ الدفع", key: "paid_at", type: "date", width: 110 },
        { label: "آخر تحديث للمراجعة", key: "review_updated_at", type: "date", width: 130 },
      ],
      rows,
    },
  ]);
}

export async function exportExternalLaborWorkbook({ dateFrom, dateTo }) {
  const actor = await generatedBy();
  const { data, error } = await supabase
    .from("daily_labor")
    .select("*,project:projects(project_code,project_name)")
    .gte("work_date", dateFrom)
    .lte("work_date", dateTo)
    .order("work_date", { ascending: true });
  if (error) throw error;
  const rows = data || [];
  download("external-labor-report", "تقرير العمالة الخارجية", { "من": dateFrom, "إلى": dateTo }, actor, [
    {
      name: "الملخص",
      summary: [
        { label: "عدد الورديات", value: rows.length, type: "number" },
        { label: "عدد العمال", value: new Set(rows.map((r) => r.worker_name)).size, type: "number" },
        { label: "إجمالي الساعات", value: sum(rows, "total_hours"), type: "number" },
        { label: "إجمالي الإضافي", value: sum(rows, "overtime_hours"), type: "number" },
        { label: "إجمالي المستحق", value: sum(rows, "total_amount"), type: "currency" },
        { label: "إجمالي المدفوع", value: sum(rows, "paid_amount"), type: "currency" },
        { label: "المتبقي", value: sum(rows, "total_amount") - sum(rows, "paid_amount"), type: "currency" },
      ],
      columns: [{ label: "حالة التقرير", width: 150, value: () => "جاهز للمراجعة" }],
      rows: rows.length ? [{}] : [],
    },
    {
      name: "الورديات",
      columns: [
        { label: "العامل", key: "worker_name", width: 150 },
        { label: "الجوال", key: "phone", width: 110 },
        { label: "الحرفة", key: "trade", width: 100 },
        { label: "المشروع", width: 150, value: (r) => r.project?.project_name || "بدون مشروع" },
        { label: "كود المشروع", width: 90, value: (r) => r.project?.project_code || "—" },
        { label: "التاريخ", key: "work_date", type: "date", width: 90 },
        { label: "بداية", key: "start_time", width: 75 },
        { label: "نهاية", key: "end_time", width: 75 },
        { label: "الراحة/دقيقة", key: "break_minutes", type: "number", width: 85 },
        { label: "الساعات", key: "total_hours", type: "number", width: 75 },
        { label: "سعر الساعة", key: "hourly_rate", type: "currency", width: 90 },
        { label: "الإضافي", key: "overtime_hours", type: "number", width: 75 },
        { label: "سعر الإضافي", key: "overtime_rate", type: "currency", width: 90 },
        { label: "الإجمالي", key: "total_amount", type: "currency", width: 95 },
        { label: "المدفوع", key: "paid_amount", type: "currency", width: 95 },
        { label: "حالة الدفع", type: "status", width: 90, value: (r) => statusLabel(r.payment_status) },
      ],
      rows,
    },
    {
      name: "المراجعة والدفع",
      columns: [
        { label: "العامل", key: "worker_name", width: 150 },
        { label: "التاريخ", key: "work_date", type: "date", width: 90 },
        { label: "حالة المراجعة", type: "status", width: 100, value: (r) => statusLabel(r.review_status) },
        { label: "سبب الرفض", key: "rejection_reason", width: 200 },
        { label: "تاريخ المراجعة", key: "reviewed_at", type: "date", width: 110 },
        { label: "مرجع الدفع", key: "payment_reference", width: 130 },
        { label: "ملاحظات الدفع", key: "payment_notes", width: 220 },
        { label: "تاريخ الدفع", key: "paid_at", type: "date", width: 110 },
        { label: "ملاحظات الوردية", key: "notes", width: 220 },
      ],
      rows,
    },
  ]);
}

function inventoryRows(workspace) {
  const balances = workspace?.balances || workspace?.inventory_balances || [];
  const items = workspace?.items || workspace?.inventory_items || [];
  const warehouses = workspace?.warehouses || workspace?.inventory_warehouses || [];
  const itemMap = new Map(items.map((item) => [item.id, item]));
  const warehouseMap = new Map(warehouses.map((warehouse) => [warehouse.id, warehouse]));
  return balances.map((balance) => ({
    ...balance,
    item: itemMap.get(balance.inventory_item_id) || {},
    warehouse: warehouseMap.get(balance.warehouse_id) || {},
  }));
}

export async function exportInventoryWorkbook() {
  const actor = await generatedBy();
  const { data, error } = await supabase.rpc("get_inventory_workspace");
  if (error) throw error;
  const workspace = data || {};
  const balances = inventoryRows(workspace);
  const movements = workspace.movements || workspace.inventory_movements || [];
  const exceptions = balances.filter((r) => num(r.quantity_on_hand) < 0 || num(r.inventory_value) < 0);
  download("inventory-report", "تقرير المخزون والمخازن", { "النطاق": "كل المخازن النشطة والمؤرشفة" }, actor, [
    {
      name: "الملخص",
      summary: [
        { label: "عدد المخازن", value: (workspace.warehouses || workspace.inventory_warehouses || []).length, type: "number" },
        { label: "عدد الأصناف", value: new Set(balances.map((r) => r.inventory_item_id)).size, type: "number" },
        { label: "إجمالي الكمية", value: sum(balances, "quantity_on_hand"), type: "number" },
        { label: "إجمالي قيمة المخزون", value: sum(balances, "inventory_value"), type: "currency" },
        { label: "عدد الاستثناءات", value: exceptions.length, type: "number" },
      ],
      columns: [{ label: "حالة التقرير", width: 150, value: () => exceptions.length ? "يحتاج مراجعة" : "سليم" }],
      rows: balances.length ? [{}] : [],
    },
    {
      name: "الأرصدة",
      columns: [
        { label: "المخزن", width: 140, value: (r) => r.warehouse.name || r.warehouse.code || r.warehouse_id },
        { label: "كود المخزن", width: 90, value: (r) => r.warehouse.code || "—" },
        { label: "الصنف", width: 160, value: (r) => r.item.name || r.inventory_item_id },
        { label: "SKU", width: 100, value: (r) => r.item.sku || "—" },
        { label: "الوحدة", width: 70, value: (r) => r.item.unit || "—" },
        { label: "الكمية المتاحة", key: "quantity_on_hand", type: "number", width: 100 },
        { label: "قيمة المخزون", key: "inventory_value", type: "currency", width: 110 },
        { label: "آخر تحديث", key: "updated_at", type: "date", width: 110 },
      ],
      rows: balances,
    },
    {
      name: "الحركات",
      columns: [
        { label: "رقم الحركة", key: "movement_number", width: 120 },
        { label: "النوع", key: "movement_type", width: 100 },
        { label: "التاريخ", key: "posted_at", type: "date", width: 110 },
        { label: "الصنف", key: "inventory_item_id", width: 140 },
        { label: "المخزن", key: "warehouse_id", width: 140 },
        { label: "تغير الكمية", key: "quantity_delta", type: "number", width: 95 },
        { label: "تكلفة الوحدة", key: "unit_cost", type: "currency", width: 100 },
        { label: "تغير القيمة", key: "value_delta", type: "currency", width: 100 },
        { label: "السبب", key: "reason", width: 200 },
      ],
      rows: movements,
    },
    {
      name: "الاستثناءات",
      columns: [
        { label: "المخزن", width: 140, value: (r) => r.warehouse.name || r.warehouse_id },
        { label: "الصنف", width: 160, value: (r) => r.item.name || r.inventory_item_id },
        { label: "الكمية", key: "quantity_on_hand", type: "number", width: 90 },
        { label: "القيمة", key: "inventory_value", type: "currency", width: 100 },
        { label: "سبب الاستثناء", width: 180, value: (r) => num(r.quantity_on_hand) < 0 ? "رصيد كمية سالب" : "قيمة مخزون سالبة" },
      ],
      rows: exceptions,
    },
  ]);
}

export function printCurrentReport() {
  window.print();
}
