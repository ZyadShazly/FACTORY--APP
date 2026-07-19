export const BUDGET_STATUSES = Object.freeze({
  draft: "مسودة", submitted: "قيد الاعتماد", approved: "معتمدة",
  rejected: "مرفوضة", superseded: "مستبدلة", cancelled: "ملغاة",
});

export const BUDGET_CATEGORY_GROUPS = Object.freeze({
  materials: {
    label: "المواد",
    items: { wood:"خشب",mdf:"MDF",plywood:"أبلكاش",hpl:"HPL",acrylic:"أكريليك",glass:"زجاج",metal:"معادن",paint:"دهانات",electrical_materials:"مواد كهربائية",accessories:"إكسسوارات",consumables:"مستهلكات",other_materials:"مواد أخرى" },
  },
  production: {
    label: "الإنتاج والمقاولات",
    items: { carpentry:"نجارة",cnc:"CNC",laser_cutting:"قص ليزر",painting:"دهان",welding:"لحام",printing:"طباعة",electrical_work:"أعمال كهرباء",assembly:"تجميع",installation:"تركيب",subcontractor:"مقاول باطن",other_production:"إنتاج آخر" },
  },
  logistics: {
    label: "النقل واللوجستيات",
    items: { transportation:"نقل",delivery:"توصيل",loading:"تحميل",unloading:"تفريغ",accommodation:"إقامة",travel:"سفر",permits:"تصاريح",site_expenses:"مصروفات موقع" },
  },
  labor: {
    label: "العمالة",
    items: { factory_employees:"موظفو المصنع",daily_labor:"عمالة يومية",overtime:"إضافي",technicians:"فنيون",site_labor:"عمالة موقع",temporary_labor:"عمالة مؤقتة" },
  },
  equipment: {
    label: "المعدات والأصول",
    items: { rented_equipment:"معدات مؤجرة",approved_asset_usage_cost:"استخدام أصل معتمد",fuel:"وقود",operation:"تشغيل",depreciation_allocation:"توزيع إهلاك",maintenance_allocation:"توزيع صيانة" },
  },
  other: {
    label: "أخرى",
    items: { direct_expenses:"مصروفات مباشرة",insurance:"تأمين",contingency:"احتياطي",overhead:"تكاليف غير مباشرة",other:"أخرى" },
  },
});

export const BUDGET_CATEGORIES = Object.freeze(Object.fromEntries(
  Object.values(BUDGET_CATEGORY_GROUPS).flatMap((group) => Object.entries(group.items)),
));

export const BUDGET_TRANSITIONS = Object.freeze({
  draft:["submitted","cancelled"], submitted:["approved","rejected"],
  approved:["superseded"], rejected:[], superseded:[], cancelled:[],
});

export function roundCurrency(value) {
  const numeric = Number(value);
  return Number.isFinite(numeric) ? Math.round((numeric + Number.EPSILON) * 100) / 100 : 0;
}

export function budgetLineTotals({ quantity = 0, unit_cost = 0, waste_percentage = 0 } = {}) {
  const qty = Number(quantity); const unitCost = Number(unit_cost); const waste = Number(waste_percentage);
  if (![qty,unitCost,waste].every(Number.isFinite) || qty < 0 || unitCost < 0 || waste < 0 || waste > 100) throw new Error("قيم بند الميزانية غير صالحة");
  const baseCost = roundCurrency(qty * unitCost);
  const wasteAmount = roundCurrency(baseCost * waste / 100);
  return { baseCost, wasteAmount, totalWithWaste:roundCurrency(baseCost + wasteAmount) };
}

export function budgetTotals(items = [], header = {}) {
  const subtotal = roundCurrency(items.reduce((sum,item) => sum + budgetLineTotals(item).totalWithWaste,0));
  const adjustment = (mode,fixed,percentage) => mode === "fixed" ? roundCurrency(fixed) : mode === "percentage" ? roundCurrency(subtotal * Number(percentage || 0) / 100) : 0;
  const contingency = adjustment(header.contingency_mode,header.contingency_amount,header.contingency_percentage);
  const overhead = adjustment(header.overhead_mode,header.overhead_amount,header.overhead_percentage);
  const expectedTotalCost = roundCurrency(subtotal + contingency + overhead);
  const targetProfit = header.target_profit_mode === "fixed" ? roundCurrency(header.target_profit_amount) : header.target_profit_mode === "percentage" ? roundCurrency(expectedTotalCost * Number(header.target_profit_percentage || 0) / 100) : 0;
  return { subtotal,contingency,overhead,expectedTotalCost,targetProfit,targetSalePrice:roundCurrency(expectedTotalCost + targetProfit) };
}

export function categoryGroupTotals(items = []) {
  return Object.fromEntries(Object.entries(BUDGET_CATEGORY_GROUPS).map(([key,group]) => [key,roundCurrency(items.filter((item) => Object.hasOwn(group.items,item.category)).reduce((sum,item) => sum + Number(item.total_with_waste ?? budgetLineTotals(item).totalWithWaste),0))]));
}

export function compareBudgetItems(oldItems = [], newItems = []) {
  const key = (item) => item.item_code || item.description;
  const oldMap = new Map(oldItems.map((item) => [key(item),item])); const newMap = new Map(newItems.map((item) => [key(item),item]));
  return [...new Set([...oldMap.keys(),...newMap.keys()])].map((compareKey) => {
    const oldItem=oldMap.get(compareKey); const newItem=newMap.get(compareKey);
    const oldAmount=oldItem ? Number(oldItem.total_with_waste ?? budgetLineTotals(oldItem).totalWithWaste) : 0;
    const newAmount=newItem ? Number(newItem.total_with_waste ?? budgetLineTotals(newItem).totalWithWaste) : 0;
    return { compare_key:compareKey,description:newItem?.description || oldItem?.description,change_type:!oldItem?"added":!newItem?"removed":"changed",old_quantity:oldItem?.quantity,new_quantity:newItem?.quantity,old_unit_cost:oldItem?.unit_cost,new_unit_cost:newItem?.unit_cost,old_waste_percentage:oldItem?.waste_percentage,new_waste_percentage:newItem?.waste_percentage,old_amount:oldAmount,new_amount:newAmount,variance_amount:roundCurrency(newAmount-oldAmount),variance_percentage:oldAmount?roundCurrency((newAmount-oldAmount)*100/oldAmount):null };
  });
}
