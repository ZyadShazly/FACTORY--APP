import React,{useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{Button,Field,Notice,Panel,friendlyError,inputStyle}from"./ui";

const emptyForm={sku:"",name:"",unit:"وحدة",materialId:"",active:true};
const rowStyle={display:"grid",gridTemplateColumns:"minmax(180px,1.2fr) minmax(180px,1fr) auto",gap:10,alignItems:"center",padding:10,border:"1px solid var(--color-border)",borderRadius:10};

export function InventoryCatalogPanel({workspace,onChanged}){
  const[busy,setBusy]=useState("");
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[search,setSearch]=useState("");
  const[links,setLinks]=useState({});
  const[showCreate,setShowCreate]=useState(false);
  const[form,setForm]=useState(emptyForm);
  const catalog=useMemo(()=>(workspace.catalog||[]).filter(i=>`${i.name} ${i.sku||""} ${i.material_name||""}`.toLowerCase().includes(search.toLowerCase())),[workspace.catalog,search]);
  const materials=(workspace.materials||[]).filter(m=>m.active!==false);
  const unlinked=workspace.unlinked_materials||[];

  function startCreate(material=null){
    setForm(material?{sku:"",name:material.name,unit:material.unit||"وحدة",materialId:material.id,active:true}:emptyForm);
    setShowCreate(true);setError("");setOk("");
  }

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
    if(done){setForm(emptyForm);setShowCreate(false)}
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

  return <>
    <Panel title="كتالوج أصناف المخزون" actions={<Button onClick={()=>startCreate()}>إنشاء صنف مخزون</Button>}>
      <p style={{color:"var(--color-text-muted)"}}>أنشئ الأصناف واربط المواد قبل الاستلام. التعطيل أو فك الربط لا يحذف أي حركة تاريخية.</p>
      {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
      {!catalog.length&&unlinked.length>0&&<Notice>
        يوجد مواد خام غير مربوطة. أنشئ صنف مخزون لبدء تسجيل الأرصدة والاستلام.
      </Notice>}
      {unlinked.length>0&&<div style={{display:"grid",gap:8,marginBottom:14}}>
        {unlinked.map(material=><div key={material.id} style={{...rowStyle,gridTemplateColumns:"1fr auto"}}>
          <span><strong>{material.name}</strong><small style={{display:"block",color:"var(--color-text-muted)"}}>غير مربوط — {material.unit||"وحدة"}</small></span>
          <Button onClick={()=>startCreate(material)}>إنشاء صنف مخزون من المادة</Button>
        </div>)}
      </div>}

      {showCreate&&<div style={{padding:12,border:"1px solid var(--color-border)",borderRadius:10,marginBottom:14}}>
        <strong>إنشاء صنف مخزون</strong>
        <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(170px,1fr))",gap:10,alignItems:"end",marginTop:10}}>
          <Field label="SKU / الكود الداخلي"><input style={inputStyle} value={form.sku} onChange={e=>setForm({...form,sku:e.target.value})}/></Field>
          <Field label="اسم الصنف"><input style={inputStyle} value={form.name} onChange={e=>setForm({...form,name:e.target.value})}/></Field>
          <Field label="الوحدة"><input style={inputStyle} value={form.unit} onChange={e=>setForm({...form,unit:e.target.value})}/></Field>
          <Field label="المادة الخام (اختياري)"><select style={inputStyle} value={form.materialId} onChange={e=>setForm({...form,materialId:e.target.value})}><option value="">غير مربوط</option>{unlinked.map(m=><option key={m.id} value={m.id}>{m.name}</option>)}</select></Field>
          <Field label="الحالة"><select style={inputStyle} value={String(form.active)} onChange={e=>setForm({...form,active:e.target.value==="true"})}><option value="true">نشط</option><option value="false">غير نشط</option></select></Field>
          <div style={{display:"flex",gap:8}}><Button disabled={busy==="create"} onClick={createItem}>حفظ الصنف</Button><Button tone="ghost" onClick={()=>setShowCreate(false)}>إلغاء</Button></div>
        </div>
      </div>}

      <input style={{...inputStyle,width:"100%",marginBottom:12}} value={search} onChange={e=>setSearch(e.target.value)} placeholder="ابحث باسم الصنف أو الكود أو المادة..."/>
      <div style={{display:"grid",gap:8}}>{catalog.map(item=>{
        const selected=links[item.id]??item.material_id??"";
        return <div key={item.id} style={rowStyle}>
          <div><strong>{item.name}</strong><small style={{display:"block",color:"var(--color-text-muted)"}}>{item.sku} — {item.active?"نشط":"غير نشط"} — {item.material_name||"غير مربوط"}</small></div>
          <select style={inputStyle} value={selected} onChange={e=>setLinks({...links,[item.id]:e.target.value})}><option value="">غير مربوط</option>{materials.map(m=><option key={m.id} value={m.id}>{m.name}</option>)}</select>
          <div style={{display:"flex",gap:6,flexWrap:"wrap"}}>
            <Button disabled={busy===item.id} onClick={()=>save(item,selected,item.active)}>حفظ الربط</Button>
            <Button tone="ghost" disabled={busy===item.id||!item.material_id} onClick={()=>save(item,"",item.active)}>فك الربط</Button>
            <Button tone="ghost" disabled={busy===item.id} onClick={()=>save(item,item.material_id,!item.active)}>{item.active?"تعطيل":"تنشيط"}</Button>
            <Button tone="danger" disabled={busy===item.id} onClick={()=>deleteItem(item)}>حذف</Button>
          </div>
        </div>
      })}{!catalog.length&&<span>لا توجد أصناف مطابقة. استخدم «إنشاء صنف مخزون» للبدء.</span>}</div>
    </Panel>
  </>;
}
