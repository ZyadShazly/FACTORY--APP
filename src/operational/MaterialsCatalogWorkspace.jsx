import React,{useEffect,useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{ConfirmDialog}from"../v22/shared";
import{runCriticalMutation}from"../v22/mutations";
import{Button,Field,Notice,Panel,friendlyError,inputStyle}from"./ui";

export function MaterialsCatalogWorkspace({data,refresh,onNavigate,canManage}){
  const[name,setName]=useState("");
  const[code,setCode]=useState("");
  const[unit,setUnit]=useState("قطعة");
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[setup,setSetup]=useState(null);
  const[busy,setBusy]=useState("");
  const[commandId,setCommandId]=useState("");
  const[itemAction,setItemAction]=useState(null);
  const[deleteAction,setDeleteAction]=useState(null);

  async function refreshSetup(){
    const{data:workspace}=await supabase.rpc("get_inventory_workspace");
    if(workspace)setSetup(workspace);
  }
  useEffect(()=>{void refreshSetup()},[data.materials]);

  const materials=setup?.materials||data.materials||[];
  const linkedByMaterial=useMemo(()=>new Map((setup?.catalog||[]).filter(i=>i.material_id).map(i=>[i.material_id,i])),[setup]);
  const identityWarnings=useMemo(()=>{
    const names=new Map(),codes=new Map();
    for(const material of materials){
      const normalizedName=material.name?.trim().replace(/\s+/g," ").toLowerCase();
      const normalizedCode=material.material_code?.trim().replace(/\s+/g,"-").toUpperCase();
      if(normalizedName)names.set(normalizedName,[...(names.get(normalizedName)||[]),material]);
      if(normalizedCode)codes.set(normalizedCode,[...(codes.get(normalizedCode)||[]),material]);
    }
    return [...names.entries()].filter(([,rows])=>rows.length>1).map(([key,rows])=>`اسم مكرر «${key}» (${rows.length})`)
      .concat([...codes.entries()].filter(([,rows])=>rows.length>1).map(([key,rows])=>`كود مكرر «${key}» (${rows.length})`));
  },[materials]);

  async function add(){
    setError("");setOk("");
    const cleanName=name.trim().replace(/\s+/g," ");
    const cleanCode=code.trim().replace(/\s+/g,"-").toUpperCase();
    if(!cleanName)return setError("اكتب اسم المادة");
    if(!cleanCode)return setError("اكتب كودًا فريدًا للمادة");
    const duplicateName=materials.find(material=>material.name?.trim().replace(/\s+/g," ").toLowerCase()===cleanName.toLowerCase());
    if(duplicateName)return setError(`المادة موجودة بالفعل باسم «${duplicateName.name}».`);
    const duplicateCode=materials.find(material=>material.material_code?.trim().replace(/\s+/g,"-").toUpperCase()===cleanCode);
    if(duplicateCode)return setError(`كود المادة «${cleanCode}» مستخدم بالفعل مع «${duplicateCode.name}».`);
    const currentCommand=commandId||globalThis.crypto.randomUUID();
    if(!commandId)setCommandId(currentCommand);
    const result=await runCriticalMutation({scope:"materials:create",mutate:()=>supabase.rpc("create_material_definition",{material_name:cleanName,material_code:cleanCode,material_unit:unit,command_id:currentCommand}),verify:async()=>{
      const verification=await supabase.from("materials").select("id").eq("command_id",currentCommand).single();
      return verification.error?verification:Boolean(verification.data?.id);
    },refetch:refresh});
    if(result.error)return setError(result.mutationSaved?"تم إرسال المادة، لكن تعذر التحقق. حدّث الصفحة قبل إعادة المحاولة.":friendlyError(result.error));
    await refreshSetup();
    setName("");setCode("");setCommandId("");setOk("تم إنشاء تعريف المادة وربطه تلقائيًا بصنف مخزون عند توفر عقد الربط.");
  }

  async function createItem(material){
    setItemAction({material,sku:""});
  }
  async function confirmCreateItem(){
    const{material,sku}=itemAction;
    if(!sku.trim())return setError("كود الصنف مطلوب.");
    setBusy(material.id);setError("");setOk("");
    const{error}=await supabase.rpc("create_inventory_item",{
      item_sku:sku.trim(),item_name:material.name,item_unit:material.unit||"وحدة",
      target_material:material.id,item_active:true
    });
    if(error){setError(friendlyError(error));setBusy("");return;}else{
      setOk("تم إنشاء صنف المخزون من المادة وربطه تلقائيًا.");
      await refreshSetup();
    }
    setBusy("");setItemAction(null);
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
    setDeleteAction({material,reason:"",busy:false,error:""});
  }
  async function confirmRemove(){
    const{material,reason}=deleteAction;
    if(!reason.trim())return setDeleteAction(current=>({...current,error:"سبب الحذف مطلوب."}));
    setDeleteAction(current=>({...current,busy:true,error:""}));
    setBusy(material.id);setError("");setOk("");
    const{error}=await supabase.rpc("delete_inventory_setup_entity",{
      entity_type:"material",target_id:material.id,deletion_reason:reason.trim()
    });
    if(error){setBusy("");return setDeleteAction(current=>({...current,busy:false,error:friendlyError(error)}));}else{
      setOk("تم حذف المادة غير المستخدمة مع حفظ بياناتها السابقة في سجل التدقيق.");
      await refreshSetup();
    }
    setBusy("");setDeleteAction(null);await refresh();
  }

  return <div>
    <h2>دليل المواد الخام</h2>
    <Notice>زيادة الرصيد لا تتم من دليل المواد مباشرة. أنشئ صنف مخزون مربوطًا ثم استخدم طلب شراء ← أمر شراء ← استلام، أو مستند الرصيد الافتتاحي.</Notice>
    {identityWarnings.length>0&&<Notice type="error">جودة بيانات تاريخية: {identityWarnings.join("، ")}. راجع السجلات ولا تدمجها أو تحذفها تلقائيًا.</Notice>}
    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
    {canManage&&<Panel title="إضافة تعريف مادة"><div style={{display:"flex",gap:10,flexWrap:"wrap",alignItems:"end"}}>
      <Field label="كود المادة"><input style={inputStyle} value={code} onChange={e=>setCode(e.target.value)} placeholder="مثال: MDF-18" autoCapitalize="characters"/></Field>
      <Field label="اسم المادة"><input style={inputStyle} value={name} onChange={e=>setName(e.target.value)}/></Field>
      <Field label="الوحدة"><input style={inputStyle} value={unit} onChange={e=>setUnit(e.target.value)}/></Field>
      <Button onClick={add}>إضافة</Button>
    </div></Panel>}
    {!canManage&&<Notice>يمكنك عرض دليل المواد فقط. إدارة التعريفات والربط والحذف متاحة للمالك أو المدير.</Notice>}
    {itemAction&&<Panel title={`إنشاء صنف مخزون — ${itemAction.material.name}`}><div style={{display:"flex",gap:10,alignItems:"end",flexWrap:"wrap"}}><Field label="SKU / الكود الداخلي"><input autoFocus style={inputStyle} value={itemAction.sku} onChange={event=>setItemAction(current=>({...current,sku:event.target.value}))}/></Field><Button disabled={busy===itemAction.material.id} onClick={confirmCreateItem}>إنشاء وربط</Button><Button tone="ghost" onClick={()=>setItemAction(null)}>إلغاء</Button></div></Panel>}
    <Panel title="المواد المعرفة"><div style={{display:"grid",gap:8}}>{materials.map(material=>{
      const linkedItem=linkedByMaterial.get(material.id);
      const linked=Boolean(linkedItem);
      return <div key={material.id} style={{display:"flex",justifyContent:"space-between",gap:10,alignItems:"center",padding:10,border:"1px solid var(--color-border)",borderRadius:9}}>
        <span><strong>{material.name}</strong> — {material.unit||"وحدة"}<small style={{display:"block",color:"var(--color-text-muted)"}}>كود المادة: {material.material_code||"قديم — يحتاج مراجعة"}</small><small style={{display:"block",color:"var(--color-text-muted)"}}>{material.active===false?"مؤرشفة":linked?`مربوطة بـ ${linkedItem.name} — ${linkedItem.sku}`:"غير مربوطة"}</small></span>
        <div style={{display:"flex",gap:6,flexWrap:"wrap"}}>
          {canManage&&!linked&&material.active!==false&&<Button disabled={busy===material.id} onClick={()=>createItem(material)}>إنشاء صنف مخزون من المادة</Button>}
          {!linked&&material.active!==false&&onNavigate&&<Button tone="ghost" onClick={()=>onNavigate("inventory")}>ربط بصنف موجود</Button>}
          {linked&&onNavigate&&<Button tone="ghost" onClick={()=>onNavigate("inventory")}>فتح صنف المخزون</Button>}
          {canManage&&<Button tone="ghost" disabled={busy===material.id} onClick={()=>setActive(material,material.active===false)}>{material.active===false?"تنشيط":"أرشفة"}</Button>}
          {canManage&&<Button tone="danger" disabled={busy===material.id} onClick={()=>remove(material)}>حذف</Button>}
        </div>
      </div>
    })}{!materials.length&&<span>لا توجد مواد معرفة.</span>}</div></Panel>
    <ConfirmDialog open={Boolean(deleteAction)} title="حذف تعريف مادة غير مستخدم" description={deleteAction?`لن يتم حذف «${deleteAction.material.name}» إذا كان له أي مرجع تشغيلي. سيُحفظ السبب والصف السابق في سجل التدقيق.`:""} confirmLabel="فحص ثم حذف" danger reasonRequired reason={deleteAction?.reason||""} busy={deleteAction?.busy} error={deleteAction?.error} onReasonChange={reason=>setDeleteAction(current=>({...current,reason,error:""}))} onConfirm={confirmRemove} onCancel={()=>setDeleteAction(null)}/>
  </div>;
}
