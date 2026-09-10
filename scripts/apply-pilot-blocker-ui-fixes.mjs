import fs from "node:fs";

function replaceExact(path, before, after) {
  const source = fs.readFileSync(path, "utf8");
  if (source.includes(after)) return false;
  if (!source.includes(before)) throw new Error(`Patch anchor missing in ${path}: ${before.slice(0,80)}`);
  fs.writeFileSync(path, source.replace(before, after));
  return true;
}

let changed = false;

changed = replaceExact(
  "src/AppMonolith.jsx",
  'import { aggregateInventoryByProduct, canonicalFinishedProductAlerts, canonicalMaterialAlerts } from "./domain/inventoryBalances";',
  'import { aggregateInventoryByMaterial, aggregateInventoryByProduct, canonicalFinishedProductAlerts, canonicalMaterialAlerts } from "./domain/inventoryBalances";'
) || changed;

changed = replaceExact(
  "src/AppMonolith.jsx",
  `function bomUnitCost(product, data) {\n  return (product.bom || []).reduce((s, r) => {\n    const m = data.materials.find((x) => x.id === r.material_id);\n    return s + (m ? m.unit_cost * r.qty : 0);\n  }, 0);\n}\nfunction productUnitCost(product, data) {\n  return bomUnitCost(product, data) + num(product.labor_cost) + num(product.overhead_cost);\n}`,
  `function materialCurrentUnitCost(materialId, data, materialBalances) {\n  const balance = materialBalances?.get(materialId);\n  if (balance && Number(balance.quantityOnHand) > 0) return Number(balance.averageUnitCost || 0);\n  const material = data.materials.find((x) => x.id === materialId);\n  return num(material?.unit_cost);\n}\nfunction bomUnitCost(product, data, materialBalances) {\n  return (product.bom || []).reduce((s, r) => s + materialCurrentUnitCost(r.material_id, data, materialBalances) * num(r.qty), 0);\n}\nfunction productUnitCost(product, data, materialBalances) {\n  return bomUnitCost(product, data, materialBalances) + num(product.labor_cost) + num(product.overhead_cost);\n}`
) || changed;

changed = replaceExact(
  "src/AppMonolith.jsx",
  '  const finishedBalances = useMemo(() => aggregateInventoryByProduct(inventoryWorkspace || {}), [inventoryWorkspace]);\n  const blank = { name: "", sku: "", laborCost: "", overheadCost: "", sellingPrice: "", itemType: "sale", commandId: "" };',
  '  const finishedBalances = useMemo(() => aggregateInventoryByProduct(inventoryWorkspace || {}), [inventoryWorkspace]);\n  const materialBalances = useMemo(() => aggregateInventoryByMaterial(inventoryWorkspace || {}), [inventoryWorkspace]);\n  const blank = { name: "", sku: "", laborCost: "", overheadCost: "", sellingPrice: "", itemType: "sale", commandId: "" };'
) || changed;

changed = replaceExact(
  "src/AppMonolith.jsx",
  '<Td>{formatMoney((m?.unit_cost || 0) * r.qty)}</Td>',
  '<Td>{formatMoney(materialCurrentUnitCost(r.material_id, data, materialBalances) * r.qty)}</Td>'
) || changed;

changed = replaceExact(
  "src/AppMonolith.jsx",
  '              const matCost = bomUnitCost(p, data);\n              const unitCost = productUnitCost(p, data);',
  '              const matCost = bomUnitCost(p, data, materialBalances);\n              const unitCost = productUnitCost(p, data, materialBalances);'
) || changed;

changed = replaceExact(
  "src/assets/AssetsPage.jsx",
  '<Input type="number" min=".001" required value={form.quantity}',
  '<Input type="number" min=".001" step=".001" required value={form.quantity}'
) || changed;

changed = replaceExact(
  "src/v23/workCalendar.jsx",
  'const blankHoliday = () => ({ name:"",start_date:localDateKey(new Date()),end_date:localDateKey(new Date()),holiday_type:"official_holiday",is_paid:true,scope_type:"company",department_id:"",employee_id:"",half_day_mode:"first_half",required_start_time:"08:00",required_end_time:"12:00",required_minutes:240,notes:"" });',
  'const blankHoliday = () => ({ name:"",start_date:localDateKey(new Date()),end_date:localDateKey(new Date()),holiday_type:"official_holiday",is_paid:true,scope_type:"company",department_id:"",employee_id:"",half_day_mode:null,required_start_time:"",required_end_time:"",required_minutes:"",notes:"" });'
) || changed;

changed = replaceExact(
  "src/v23/workCalendar.jsx",
  '<Select value={form.holiday_type} onChange={e=>setForm({...form,holiday_type:e.target.value})}>',
  '<Select value={form.holiday_type} onChange={e=>{const holiday_type=e.target.value;const timed=["half_day","working_day_override"].includes(holiday_type);setForm({...form,holiday_type,...(timed?{half_day_mode:holiday_type==="half_day"?(form.half_day_mode||"first_half"):null,required_start_time:form.required_start_time||"08:00",required_end_time:form.required_end_time||"12:00",required_minutes:Number(form.required_minutes||240)}:{half_day_mode:null,required_start_time:"",required_end_time:"",required_minutes:""})})}}>'
) || changed;

changed = replaceExact(
  "src/reporting/professionalExports.js",
  `  const { data, error } = await supabase\n    .from("daily_labor")\n    .select("*,project:projects(project_code,project_name)")\n    .gte("work_date", dateFrom)\n    .lte("work_date", dateTo)\n    .order("work_date", { ascending: true });`,
  `  const { data, error } = await supabase.rpc("get_external_labor_export", {\n    date_from: dateFrom, date_to: dateTo,\n  });`
) || changed;

console.log(changed ? "Pilot blocker UI fixes applied." : "Pilot blocker UI fixes already applied.");
