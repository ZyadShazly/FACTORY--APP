import React from "react";
export {
  ArchiveSection,
  DependencySummary,
  DetailsDrawer,
  EmptyState as FoundationEmptyState,
  HelpText,
  KpiCard,
  KpiGrid,
  MAX_KPI_CARDS,
  PageHeader,
  PrimaryActionBar,
  ResponsiveCardGrid,
  ResponsiveTable,
  SearchFilterBar,
  StatusBadge,
} from "../ui/index.js";

export const money=(v)=>new Intl.NumberFormat("ar-EG",{minimumFractionDigits:2,maximumFractionDigits:2}).format(Number(v||0));
export const dateText=(v)=>v?new Date(v).toLocaleDateString("ar-EG"):"—";
export const inputStyle={border:"1px solid var(--color-border)",borderRadius:9,padding:"9px 10px",background:"var(--color-surface)",color:"var(--color-text)"};
export function friendlyError(error){const t=String(error?.message||error||"تعذر تنفيذ العملية");const m=[
["Production access required","لا توجد صلاحية للوصول إلى أوامر الإنتاج."],
["Production create access required","لا توجد صلاحية لإنشاء أمر إنتاج."],
["Production planning access required","لا توجد صلاحية لتخطيط أمر الإنتاج."],
["Production release access required","لا توجد صلاحية لإصدار أمر الإنتاج."],
["Production material issue access required","لا توجد صلاحية لصرف خامات الإنتاج."],
["Production operation access required","لا توجد صلاحية لتحديث خطوات الإنتاج."],
["Production completion access required","لا توجد صلاحية لإكمال أمر الإنتاج."],
["BOM material is not linked to an active inventory item","يوجد مكوّن في تركيبة المنتج غير مربوط بصنف مخزني نشط."],
["Warehouse is required for product materials","اختر المخزن الذي ستُصرف منه خامات الأمر."],
["Production order must be linked to a project","اربط أمر الإنتاج بمشروع قبل الإصدار."],
["At least one material requirement is required","لا توجد خامات مطلوبة مرتبطة بأمر الإنتاج."],
["Full required quantity must be issued exactly once","يجب صرف الكمية المطلوبة كاملة مرة واحدة."],
["Insufficient inventory balance","الرصيد المتاح لا يكفي للصرف."],
["Owner or manager role required","تتطلب العملية صلاحية المالك أو المدير."],
["Inventory SKU already exists","كود الصنف مستخدم بالفعل. أدخل كودًا داخليًا مختلفًا."],
["Material is already linked to another inventory item","هذه المادة مربوطة بالفعل بصنف مخزون آخر."],
["Active raw material is required","اختر مادة خام نشطة."],
["Cannot deactivate an inventory item with stock","لا يمكن تعطيل صنف له رصيد. صفّر الرصيد بالتسوية أو التحويل أولًا."],
["Inventory item has operational references","لا يمكن حذف الصنف لوجود مراجع تشغيلية. استخدم التعطيل بدلًا من الحذف."],
["Raw material has operational references","لا يمكن حذف المادة لوجود مراجع تشغيلية. استخدم الأرشفة بدلًا من الحذف."],
["Deletion reason is required","سبب الحذف مطلوب."],
["Opening quantity must be greater than zero","الكمية الافتتاحية يجب أن تكون أكبر من صفر."],
["Opening unit cost cannot be negative","تكلفة الوحدة الافتتاحية لا يمكن أن تكون سالبة."],
["Active inventory item required","اختر صنف مخزون نشطًا."],
["Active warehouse required","اختر مخزنًا نشطًا."],
["Active warehouse location required","الموقع المختار غير نشط أو لا يتبع المخزن."],
["Opening inventory document is already posted","تم ترحيل مستند الرصيد الافتتاحي مسبقًا ولا يمكن ترحيله مرتين."],
["Posted opening inventory","مستند الرصيد الافتتاحي المرحّل غير قابل للتعديل أو الحذف."],
["The item, warehouse, and location already exist","هذا الصنف والمخزن والموقع مضاف بالفعل إلى المستند."]
];for(const[n,l]of m)if(t.includes(n))return l;return"تعذر تنفيذ العملية. راجع المدخلات والصلاحيات ثم حاول مرة أخرى.";}
export function Panel({title,children,actions}){return <section style={{background:"var(--color-surface)",border:"1px solid var(--color-border)",borderRadius:14,padding:16,marginBottom:16}}><div style={{display:"flex",justifyContent:"space-between",gap:12,alignItems:"center",marginBottom:12}}><strong>{title}</strong>{actions}</div>{children}</section>}
export function Button({children,onClick,disabled,tone="primary"}){return <button type="button" onClick={onClick} disabled={disabled} style={{border:0,borderRadius:9,padding:"9px 13px",cursor:disabled?"not-allowed":"pointer",fontWeight:700,background:tone==="danger"?"var(--color-danger)":tone==="ghost"?"var(--color-surface-muted)":"var(--color-wood)",color:tone==="ghost"?"var(--color-text)":"#fff",opacity:disabled?.55:1}}>{children}</button>}
export function Notice({type="info",children}){return <div style={{padding:12,borderRadius:10,marginBottom:12,background:type==="error"?"color-mix(in srgb,var(--color-danger) 12%,transparent)":"var(--color-surface-muted)",color:type==="error"?"var(--color-danger)":"var(--color-text)"}}>{children}</div>}
export function Field({label,children}){return <label style={{display:"grid",gap:6,fontSize:13,minWidth:170}}><span>{label}</span>{children}</label>}
