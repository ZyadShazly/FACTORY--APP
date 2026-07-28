import React,{useEffect,useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{Button,Field,Notice,Panel,friendlyError,inputStyle,money}from"./ui";

const emptyForm={sku:"",name:"",unit:"وحدة",materialId:"",active:true};

export function InventoryCatalogPanel({workspace,onChanged,onOpenMaterials,canManage=false,createRequest=0}){
  const[busy,setBusy]=useState("");
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[search,setSearch]=useState("");
  const[stockKind,setStockKind]=useState("raw");
  const[links,setLinks]=useState({});
  const[showCreate,setShowCreate]=useState(false);
  const[form,setForm]=useState(emptyForm);
  const sourceCatalog=(workspace.catalog||[]).length?workspace.catalog:(workspace.items||[]);
  const rawItems=useMemo(()=>sourceCatalog.filter(item=>Boolean(item.material_id||item.material_name)),[sourceCatalog]);
  const finishedItems=useMemo(()=>sourceCatalog.filter(item=>!item.material_id&&!item.material_name),[sourceCatalog]);
  const selectedSource=stockKind==="raw"?rawItems:finishedItems;
  const catalog=useMemo(()=>selectedSource.filter(item=>`${item.name} ${item.sku||""} ${item.material_name||""}`.toLowerCase().includes(search.toLowerCase())),[selectedSource,search]);
  const materials=(workspace.materials||[]).filter(material=>material.active!==false);
  const unlinked=workspace.unlinked_materials||[];
  const linkedMaterialIds=useMemo(()=>new Set(sourceCatalog.map(item=>item.material_id).filter(Boolean)),[sourceCatalog]);
  const balanceSummary=useMemo(()=>{
    const summary=new Map();
    for(const row of workspace.balances||[]){
      const current=summary.get(row.inventory_item_id)||{quantity:0,warehouses:new Set()};
      current.quantity+=Number(row.quantity_on_hand||0);
      if(row.warehouse_name)current.warehouses.add(row.warehouse_name);
      summary.set(row.inventory_item_id,current);
    }
    return summary;
  },[workspace.balances]);
  const rawBalance=useMemo(()=>rawItems.reduce((sum,item)=>sum+(balanceSummary.get(item.id)?.quantity||0),0),[rawItems,balanceSummary]);
  const finishedBalance=useMemo(()=>finishedItems.reduce((sum,item)=>sum+(balanceSummary.get(item.id)?.quantity||0),0),[finishedItems,balanceSummary]);

  function startCreate(material=null){
    setForm(material?{sku:"",name:material.name,unit:material.unit||"وحدة",materialId:material.id,active:true}:emptyForm);
    setShowCreate(true);setError("");setOk("");
  }
  useEffect(()=>{if(createRequest>0)startCreate()},[createRequest]);

  async function run(key,name,args,success){
    setBusy(key);setError("");setOk("");
    const{error}=await supabase.rpc(name,args);
    if(error)setError(friendlyError(error));else{setOk(success);await onChanged()}
    setBusy("");
    return !error;
  }

  async function createItem(){
    if(!form.sku.trim())return setError("أدخل كود الصنف الداخلي.");
    if(!form.name.trim())return setError("أدخل اسم الصنف.");
    if(!form.unit.trim())return setError("أدخل وحدة الصنف.");
    const done=await run("create","create_inventory_item",{
      item_sku:form.sku.trim(),item_name:form.name.trim(),item_unit:form.unit.trim(),
      target_material:form.materialId||null,item_active:form.active
    },"تم إنشاء صنف المخزون وتسجيل العملية في سجل التدقيق.");
    if(done){setForm(emptyForm);setShowCreate(false);setStockKind(form.materialId?"raw":"finished")}
  }

  async function save(item,materialId,active){
    await run(item.id,"manage_inventory_item_catalog",{
      target_item:item.id,target_material:materialId||null,target_active:active
    },"تم تحديث صنف المخزون.");
  }

  async function deleteItem(item){
    const reason=window.prompt(`اكتب سبب حذف الصنف "${item.name}". لن يتم الحذف إذا كان مستخدمًا تشغيليًا.`);
    if(reason===null)return;
    if(!reason.trim())return setError("سبب الحذف مطلوب.");
    await run(item.id,"delete_inventory_setup_entity",{
      entity_type:"inventory_item",target_id:item.id,deletion_reason:reason.trim()
    },"تم حذف الصنف غير المستخدم مع حفظ بياناته السابقة في سجل التدقيق.");
  }

  return <Panel title="أصناف المخزون" actions={canManage&&<Button onClick={()=>startCreate()}>+ صنف جديد</Button>}>
    <div className="inventory-section-heading">
      <div><h3>أرصدة المواد الخام والمنتجات التامة</h3><p>اختر نوع المخزون أولًا حتى تظهر لك الأرصدة المهمة فقط، مع بقاء الربط والحركات التاريخية كما هي.</p></div>
      {onOpenMaterials&&<Button tone="ghost" onClick={onOpenMaterials}>فتح المواد الخام</Button>}
    </div>
    <div className="inventory-balance-switch" role="tablist" aria-label="نوع رصيد المخزون">
      <button type="button" role="tab" aria-selected={stockKind==="raw"} className={stockKind==="raw"?"is-active":""} onClick={()=>setStockKind("raw")}>
        <span>المواد الخام</span><strong>{money(rawBalance)}</strong><small>{rawItems.length} صنف</small>
      </button>
      <button type="button" role="tab" aria-selected={stockKind==="finished"} className={stockKind==="finished"?"is-active":""} onClick={()=>setStockKind("finished")}>
        <span>المنتجات التامة</span><strong>{money(finishedBalance)}</strong><small>{finishedItems.length} صنف</small>
      </button>
    </div>
    <details className="inventory-concepts">
      <summary>ما الفرق بين المادة الخام وصنف المخزون والرصيد والحركة؟</summary>
      <dl>
        <div><dt>المادة الخام</dt><dd>تعريف ما تشتريه أو تستخدمه في الإنتاج.</dd></div>
        <div><dt>صنف المخزون</dt><dd>الكود الذي يربط المادة بدفتر المخزون.</dd></div>
        <div><dt>المنتج التام</dt><dd>صنف مخزون غير مربوط بمادة خام ويظهر في رصيد المنتجات التامة.</dd></div>
        <div><dt>رصيد المخزن</dt><dd>الكمية والقيمة الحالية لصنف داخل مخزن محدد.</dd></div>
        <div><dt>الرصيد الافتتاحي</dt><dd>مستند مستقل لإدخال مخزون المصنع الموجود قبل بدء النظام.</dd></div>
        <div><dt>حركة المخزون</dt><dd>سجل غير قابل للمحو لكل استلام أو صرف أو تحويل أو تسوية.</dd></div>
      </dl>
    </details>
    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
    {canManage&&unlinked.length>0&&<Notice>يوجد مواد خام غير مربوطة. أنشئ صنف مخزون لبدء تسجيل الأرصدة والاستلام.</Notice>}

    {canManage&&unlinked.length>0&&<details className="inventory-materials">
      <summary>مواد خام غير مربوطة ({unlinked.length}) — إنشاء صنف من مادة</summary>
      <div className="inventory-material-list">{unlinked.map(material=><div key={material.id} className="inventory-material-row">
        <span><strong>{material.name}</strong><small style={{display:"block",color:"var(--color-text-muted)"}}>{material.unit||"وحدة"}</small></span>
        <Button onClick={()=>startCreate(material)}>إنشاء من المادة</Button>
      </div>)}</div>
    </details>}

    {canManage&&showCreate&&<div className="inventory-create-form">
      <strong>إنشاء صنف مخزون</strong>
      <div className="inventory-form-grid">
        <Field label="SKU / الكود الداخلي"><input style={inputStyle} value={form.sku} onChange={event=>setForm({...form,sku:event.target.value})}/></Field>
        <Field label="اسم الصنف"><input style={inputStyle} value={form.name} onChange={event=>setForm({...form,name:event.target.value})}/></Field>
        <Field label="الوحدة"><input style={inputStyle} value={form.unit} onChange={event=>setForm({...form,unit:event.target.value})}/></Field>
        <Field label="المادة الخام (اتركها فارغة للمنتج التام)"><select style={inputStyle} value={form.materialId} onChange={event=>setForm({...form,materialId:event.target.value})}><option value="">منتج تام / غير مربوط بمادة خام</option>{unlinked.map(material=><option key={material.id} value={material.id}>{material.name}</option>)}</select></Field>
        <Field label="الحالة"><select style={inputStyle} value={String(form.active)} onChange={event=>setForm({...form,active:event.target.value==="true"})}><option value="true">نشط</option><option value="false">غير نشط</option></select></Field>
        <div className="inventory-row-actions"><Button disabled={busy==="create"} onClick={createItem}>حفظ الصنف</Button><Button tone="ghost" onClick={()=>setShowCreate(false)}>إلغاء</Button></div>
      </div>
    </div>}

    <input style={{...inputStyle,width:"100%",marginBottom:12}} value={search} onChange={event=>setSearch(event.target.value)} placeholder={stockKind==="raw"?"ابحث في المواد الخام بالاسم أو الكود...":"ابحث في المنتجات التامة بالاسم أو الكود..."}/>
    <div className="inventory-table-wrap"><table className="inventory-table"><thead><tr>{["الاسم","الكود","الكمية","المخزن","الحالة","المادة المرتبطة",...(canManage?["الإجراءات"]:[])].map(header=><th key={header}>{header}</th>)}</tr></thead><tbody>
      {catalog.map(item=>{
        const selected=links[item.id]??item.material_id??"";
        const summary=balanceSummary.get(item.id)||{quantity:0,warehouses:new Set()};
        const availableMaterials=materials.filter(material=>material.id===item.material_id||!linkedMaterialIds.has(material.id));
        return <tr key={item.id}>
          <td><span className="inventory-item-name"><strong>{item.name}</strong><small>{item.unit||"وحدة"}</small></span></td>
          <td>{item.sku||"—"}</td>
          <td>{money(summary.quantity)}</td>
          <td>{[...summary.warehouses].join("، ")||"لا يوجد رصيد"}</td>
          <td><span className={`inventory-status${item.active===false?" is-inactive":""}`}>{item.active===false?"غير نشط":"نشط"}</span></td>
          <td>{canManage?<select style={inputStyle} value={selected} onChange={event=>setLinks({...links,[item.id]:event.target.value})}><option value="">منتج تام / غير مربوط</option>{availableMaterials.map(material=><option key={material.id} value={material.id}>{material.name}</option>)}</select>:item.material_name||(stockKind==="finished"?"منتج تام":"غير مربوط")}</td>
          {canManage&&<td><div className="inventory-row-actions">
            <Button disabled={busy===item.id||selected===(item.material_id||"")} onClick={()=>save(item,selected,item.active)}>حفظ الربط</Button>
            <Button tone="ghost" disabled={busy===item.id||!item.material_id} onClick={()=>save(item,"",item.active)}>تحويل لمنتج تام</Button>
            <Button tone="ghost" disabled={busy===item.id} onClick={()=>save(item,item.material_id,!item.active)}>{item.active===false?"تنشيط":"تعطيل"}</Button>
            <details className="inventory-row-more"><summary>المزيد</summary><div><Button tone="danger" disabled={busy===item.id} onClick={()=>deleteItem(item)}>حذف غير مستخدم</Button></div></details>
          </div></td>}
        </tr>
      })}
      {!catalog.length&&<tr><td colSpan={canManage?7:6} className="inventory-empty">لا توجد {stockKind==="raw"?"مواد خام":"منتجات تامة"} مطابقة.</td></tr>}
    </tbody></table></div>
  </Panel>;
}