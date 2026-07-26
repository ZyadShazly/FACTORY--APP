import React,{useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{Button,Notice,Panel,friendlyError}from"./ui";

const selectStyle={width:"100%",padding:8,border:"1px solid var(--color-border)",borderRadius:8,background:"var(--color-surface)",color:"inherit"};

export function InventoryCatalogPanel({workspace,onChanged}){
  const[busy,setBusy]=useState("");
  const[error,setError]=useState("");
  const[search,setSearch]=useState("");
  const[links,setLinks]=useState({});
  const catalog=useMemo(()=>(workspace.catalog||[]).filter(i=>`${i.name} ${i.sku||""} ${i.material_name||""}`.toLowerCase().includes(search.toLowerCase())),[workspace.catalog,search]);
  const materials=workspace.materials||[];

  async function save(item,materialId,active){
    setBusy(item.id);setError("");
    const{error}=await supabase.rpc("manage_inventory_item_catalog",{target_item:item.id,target_material:materialId||null,target_active:active});
    if(error)setError(friendlyError(error));else await onChanged();
    setBusy("");
  }

  return <Panel title="كتالوج أصناف المخزون">
    <p style={{color:"var(--color-text-muted)"}}>اربط كل مادة بصنف مخزون نشط قبل الاستلام. فك الربط أو التعطيل لا يحذف أي حركة تاريخية.</p>
    {error&&<Notice type="error">{error}</Notice>}
    <input style={{...selectStyle,marginBottom:12}} value={search} onChange={e=>setSearch(e.target.value)} placeholder="ابحث باسم الصنف أو الكود أو المادة..."/>
    <div style={{display:"grid",gap:8}}>{catalog.map(item=>{
      const selected=links[item.id]??item.material_id??"";
      return <div key={item.id} style={{display:"grid",gridTemplateColumns:"minmax(180px,1.2fr) minmax(180px,1fr) auto",gap:10,alignItems:"center",padding:10,border:"1px solid var(--color-border)",borderRadius:10}}>
        <div><strong>{item.name}</strong><small style={{display:"block",color:"var(--color-text-muted)"}}>{item.sku||"بدون كود"} — {item.active?"نشط":"غير نشط"}</small></div>
        <select style={selectStyle} value={selected} onChange={e=>setLinks({...links,[item.id]:e.target.value})}><option value="">غير مربوط</option>{materials.map(m=><option key={m.id} value={m.id}>{m.name}</option>)}</select>
        <div style={{display:"flex",gap:6,flexWrap:"wrap"}}>
          <Button disabled={busy===item.id} onClick={()=>save(item,selected,item.active)}>حفظ الربط</Button>
          <Button disabled={busy===item.id||!item.material_id} onClick={()=>save(item,"",item.active)}>فك الربط</Button>
          <Button disabled={busy===item.id} onClick={()=>save(item,item.material_id,!item.active)}>{item.active?"تعطيل":"تنشيط"}</Button>
        </div>
      </div>
    })}{!catalog.length&&<span>لا توجد أصناف مطابقة.</span>}</div>
  </Panel>;
}
