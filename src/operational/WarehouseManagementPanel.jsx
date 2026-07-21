import React,{useState}from"react";
import{supabase}from"../supabaseClient";
import{Button,Notice,Panel,friendlyError,money}from"./ui";

const fieldStyle={width:"100%",padding:10,border:"1px solid var(--color-border)",borderRadius:9,background:"var(--color-surface)",color:"inherit"};
const grid={display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(180px,1fr))",gap:10,alignItems:"end"};
function Field({label,...props}){return <label style={{display:"grid",gap:6}}><span>{label}</span><input style={fieldStyle}{...props}/></label>}
function Info({label,value}){return <div><small style={{display:"block",color:"var(--color-text-muted)"}}>{label}</small><strong>{value}</strong></div>}

export function WarehouseManagementPanel({workspace,onChanged,canViewFinancials=true}){
  const[form,setForm]=useState({id:null,code:"",name:""});
  const[location,setLocation]=useState({id:null,warehouse:"",code:"",name:""});
  const[detail,setDetail]=useState(null);
  const[archiveReason,setArchiveReason]=useState("");
  const[busy,setBusy]=useState(false);
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const warehouses=workspace.warehouse_admin||workspace.warehouses||[];

  async function rpc(name,args){setBusy(true);setError("");setOk("");const{data,error}=await supabase.rpc(name,args);setBusy(false);if(error){setError(friendlyError(error));return null}return data}
  async function saveWarehouse(){if(!form.code.trim()||!form.name.trim())return setError("اكتب كود المخزن واسمه");const data=await rpc("save_inventory_warehouse",{target_id:form.id,warehouse_code:form.code,warehouse_name:form.name});if(!data)return;setOk(form.id?"تم تحديث بيانات المخزن مع الحفاظ على تاريخه.":"تم إنشاء المخزن.");setForm({id:null,code:"",name:""});await onChanged()}
  async function saveLocation(){if(!location.warehouse||!location.code.trim()||!location.name.trim())return setError("اختر المخزن واكتب كود الموقع واسمه");const data=await rpc("save_inventory_location",{target_id:location.id,target_warehouse:location.warehouse,location_code:location.code,location_name:location.name});if(!data)return;setOk(location.id?"تم تحديث موقع التخزين.":"تمت إضافة موقع التخزين.");setLocation({id:null,warehouse:"",code:"",name:""});await onChanged();if(detail)await openDetail(detail.warehouse.id)}
  async function openDetail(id){const data=await rpc("get_inventory_warehouse_detail",{target_warehouse:id});if(data)setDetail(data)}
  async function archive(){if(!detail?.warehouse?.id)return;if(!archiveReason.trim())return setError("سبب الأرشفة مطلوب");if(!window.confirm("سيتم إيقاف المخزن وكل مواقعه عن العمليات الجديدة مع الحفاظ على تاريخه. متابعة؟"))return;const data=await rpc("archive_inventory_warehouse",{target_warehouse:detail.warehouse.id,reason:archiveReason.trim()});if(!data)return;setOk("تمت أرشفة المخزن مع الحفاظ على الحركات والأرصدة التاريخية.");setArchiveReason("");setDetail(null);await onChanged()}

  return <Panel title="إدارة المخازن ومواقع التخزين">
    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
    <div style={grid}>
      <Field label="كود المخزن" value={form.code} onChange={e=>setForm({...form,code:e.target.value})}/>
      <Field label="اسم المخزن" value={form.name} onChange={e=>setForm({...form,name:e.target.value})}/>
      <Button disabled={busy} onClick={saveWarehouse}>{form.id?"حفظ تعديل المخزن":"إضافة مخزن"}</Button>
      {form.id&&<Button tone="ghost" onClick={()=>setForm({id:null,code:"",name:""})}>إلغاء التعديل</Button>}
    </div>
    <div style={{overflowX:"auto",marginTop:14}}><table style={{width:"100%",borderCollapse:"collapse"}}><thead><tr>{["الكود","المخزن","الحالة","الإجراءات"].map(h=><th key={h} style={{textAlign:"right",padding:9,borderBottom:"1px solid var(--color-border)"}}>{h}</th>)}</tr></thead><tbody>{warehouses.map(w=><tr key={w.id}><td style={{padding:9}}>{w.code}</td><td>{w.name}</td><td>{w.active?"نشط":"مؤرشف"}</td><td><div style={{display:"flex",gap:6,flexWrap:"wrap"}}><Button tone="ghost" onClick={()=>openDetail(w.id)}>فتح التفاصيل</Button>{w.active&&<Button tone="ghost" onClick={()=>setForm({id:w.id,code:w.code,name:w.name})}>تعديل</Button>}</div></td></tr>)}</tbody></table></div>
    <hr style={{border:0,borderTop:"1px solid var(--color-border)",margin:"18px 0"}}/>
    <h4>إضافة أو تعديل موقع تخزين</h4>
    <div style={grid}>
      <label style={{display:"grid",gap:6}}><span>المخزن</span><select style={fieldStyle} value={location.warehouse} onChange={e=>setLocation({...location,warehouse:e.target.value,id:null})}><option value="">اختر</option>{(workspace.warehouses||[]).map(w=><option key={w.id} value={w.id}>{w.name}</option>)}</select></label>
      <Field label="كود الموقع" value={location.code} onChange={e=>setLocation({...location,code:e.target.value})}/>
      <Field label="اسم الموقع" value={location.name} onChange={e=>setLocation({...location,name:e.target.value})}/>
      <Button disabled={busy} onClick={saveLocation}>{location.id?"حفظ تعديل الموقع":"إضافة موقع"}</Button>
    </div>
    {detail&&<div style={{marginTop:18,padding:14,border:"1px solid var(--color-border)",borderRadius:10}}>
      <div style={{display:"flex",justifyContent:"space-between",gap:10,flexWrap:"wrap"}}><div><h3 style={{margin:0}}>{detail.warehouse.name}</h3><small>{detail.warehouse.code} — {detail.warehouse.active?"نشط":"مؤرشف"}</small></div><Button tone="ghost" onClick={()=>setDetail(null)}>إغلاق</Button></div>
      <div style={{...grid,marginTop:14}}><Info label="إجمالي الكمية" value={money(detail.summary.quantity_on_hand)}/>{canViewFinancials&&<Info label="قيمة المخزون" value={money(detail.summary.inventory_value)}/>}<Info label="الحركات" value={detail.summary.movement_count}/><Info label="استلامات مرتبطة" value={detail.summary.receipt_links}/><Info label="روابط إنتاج" value={detail.summary.production_links}/><Info label="جلسات جرد مفتوحة" value={detail.summary.open_count_sessions}/></div>
      <h4>مواقع التخزين</h4>{detail.locations.map(l=><div key={l.id} style={{display:"flex",justifyContent:"space-between",gap:8,padding:"7px 0",borderBottom:"1px solid var(--color-border)"}}><span>{l.code} — {l.name} {!l.active&&"(مؤرشف)"}</span>{l.active&&detail.warehouse.active&&<Button tone="ghost" onClick={()=>setLocation({id:l.id,warehouse:l.warehouse_id,code:l.code,name:l.name})}>تعديل</Button>}</div>)}{!detail.locations.length&&<p>لا توجد مواقع تخزين.</p>}
      <h4>الأرصدة</h4>{detail.balances.map(b=><div key={b.inventory_item_id} style={{display:"flex",justifyContent:"space-between",gap:8,padding:"7px 0",borderBottom:"1px solid var(--color-border)"}}><span>{b.item_name}</span><strong>{money(b.quantity_on_hand)} {b.unit}</strong></div>)}{!detail.balances.length&&<p>لا توجد أرصدة مسجلة.</p>}
      {detail.warehouse.active&&<><Notice type={Number(detail.summary.quantity_on_hand)!==0||Number(detail.summary.open_count_sessions)>0?"error":"info"}>{Number(detail.summary.quantity_on_hand)!==0?"لا يمكن الأرشفة قبل تحويل أو تسوية كل الأرصدة إلى صفر.":Number(detail.summary.open_count_sessions)>0?"لا يمكن الأرشفة مع وجود جلسة جرد مفتوحة.":"المخزن قابل للأرشفة، وسيظل تاريخه وحركاته محفوظين."}</Notice><div style={grid}><Field label="سبب الأرشفة" value={archiveReason} onChange={e=>setArchiveReason(e.target.value)}/><Button disabled={busy||Number(detail.summary.quantity_on_hand)!==0||Number(detail.summary.open_count_sessions)>0} onClick={archive}>أرشفة المخزن</Button></div></>}
    </div>}
  </Panel>;
}
