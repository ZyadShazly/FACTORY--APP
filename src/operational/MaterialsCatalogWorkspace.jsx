import React,{useEffect,useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{Button,Field,Notice,Panel,friendlyError,inputStyle}from"./ui";

export function MaterialsCatalogWorkspace({data,insertRow,onNavigate}){
  const[name,setName]=useState("");
  const[unit,setUnit]=useState("قطعة");
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[setup,setSetup]=useState(null);
  const[busy,setBusy]=useState("");

  async function refreshSetup(){
    const{data:workspace}=await supabase.rpc("get_inventory_workspace");
    if(workspace)setSetup(workspace);
  }
  useEffect(()=>{void refreshSetup()},[data.materials]);

  const materials=setup?.materials||data.materials||[];
  const linkedByMaterial=useMemo(()=>new Map((setup?.catalog||[]).filter(i=>i.material_id).map(i=>[i.material_id,i])),[setup]);

  async function add(){
    setError("");setOk("");
    if(!name.trim())return setError("اكتب اسم المادة");
    const e=await insertRow("materials",{name:name.trim(),unit,unit_cost:0,initial_stock:0});
    if(e)return setError(friendlyError(e));
    await refreshSetup();
    setName("");setOk("تم إنشاء تعريف المادة. أنشئ صنف مخزون مربوطًا بها قبل الاستلام.");
  }

  async function createItem(material){
    const sku=window.prompt(`أدخل SKU / الكود الداخلي لصنف "${material.name}".`);
    if(sku===null)return;
    if(!sku.trim())return setError("كود الصنف مطلوب.");
    setBusy(material.id);setError("");setOk("");
    const{error}=await supabase.rpc("create_inventory_item",{
      item_sku:sku.trim(),item_name:material.name,item_unit:material.unit||"وحدة",
      target_material:material.id,item_active:true
    });
    if(error)setError(friendlyError(error));else{
      setOk("تم إنشاء صنف المخزون من المادة وربطه تلقائيًا.");
      await refreshSetup();
    }
    setBusy("");
  }

  async function setActive(material,active){
    setBusy(material.id);setError("");setOk("");
    const{error}=await supabase.rpc("set_material_active",{target_material:material.id,target_active:active});
    if(error)setError(friendlyError(error));else{
      setOk(active?"تم تنشيط المادة.":"تمت أرشفة المادة مع الحفاظ على السجل التاريخي.");
      await refreshSetup();
    }
    setBusy("");
  }

  async function remove(material){
    const reason=window.prompt(`اكتب سبب حذف المادة "${material.name}". لن يتم الحذف إذا كانت مستخدمة تشغيليًا.`);
    if(reason===null)return;
    if(!reason.trim())return setError("سبب الحذف مطلوب.");
    setBusy(material.id);setError("");setOk("");
    const{error}=await supabase.rpc("delete_inventory_setup_entity",{
      entity_type:"material",target_id:material.id,deletion_reason:reason.trim()
    });
    if(error)setError(friendlyError(error));else{
      setOk("تم حذف المادة غير المستخدمة مع حفظ بياناتها السابقة في سجل التدقيق.");
      await refreshSetup();
    }
    setBusy("");
  }

  return <div>
    <h2>دليل المواد الخام</h2>
    <Notice>زيادة الرصيد لا تتم من دليل المواد مباشرة. أنشئ صنف مخزون مربوطًا ثم استخدم طلب شراء ← أمر شراء ← استلام، أو مستند الرصيد الافتتاحي.</Notice>
    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
    <Panel title="إضافة تعريف مادة"><div style={{display:"flex",gap:10,flexWrap:"wrap",alignItems:"end"}}>
      <Field label="اسم المادة"><input style={inputStyle} value={name} onChange={e=>setName(e.target.value)}/></Field>
      <Field label="الوحدة"><input style={inputStyle} value={unit} onChange={e=>setUnit(e.target.value)}/></Field>
      <Button onClick={add}>إضافة</Button>
    </div></Panel>
    <Panel title="المواد المعرفة"><div style={{display:"grid",gap:8}}>{materials.map(material=>{
      const linkedItem=linkedByMaterial.get(material.id);
      const linked=Boolean(linkedItem);
      return <div key={material.id} style={{display:"flex",justifyContent:"space-between",gap:10,alignItems:"center",padding:10,border:"1px solid var(--color-border)",borderRadius:9}}>
        <span><strong>{material.name}</strong> — {material.unit||"وحدة"}<small style={{display:"block",color:"var(--color-text-muted)"}}>{material.active===false?"مؤرشفة":linked?`مربوطة بـ ${linkedItem.name} — ${linkedItem.sku}`:"غير مربوطة"}</small></span>
        <div style={{display:"flex",gap:6,flexWrap:"wrap"}}>
          {!linked&&material.active!==false&&<Button disabled={busy===material.id} onClick={()=>createItem(material)}>إنشاء صنف مخزون من المادة</Button>}
          {!linked&&material.active!==false&&onNavigate&&<Button tone="ghost" onClick={()=>onNavigate("inventory")}>ربط بصنف موجود</Button>}
          {linked&&onNavigate&&<Button tone="ghost" onClick={()=>onNavigate("inventory")}>فتح صنف المخزون</Button>}
          <Button tone="ghost" disabled={busy===material.id} onClick={()=>setActive(material,material.active===false)}>{material.active===false?"تنشيط":"أرشفة"}</Button>
          <Button tone="danger" disabled={busy===material.id} onClick={()=>remove(material)}>حذف</Button>
        </div>
      </div>
    })}{!materials.length&&<span>لا توجد مواد معرفة.</span>}</div></Panel>
  </div>;
}
