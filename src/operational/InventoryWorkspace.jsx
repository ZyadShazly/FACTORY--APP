import React,{useEffect,useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{Button,Notice,Panel,friendlyError,money}from"./ui";
import{WarehouseManagementPanel}from"./WarehouseManagementPanel";

const emptyWorkspace={items:[],balances:[],warehouses:[],warehouse_admin:[],locations:[],movements:[],count_sessions:[],count_lines:[],capabilities:{}};
const inputStyle={width:"100%",padding:10,border:"1px solid var(--color-border)",borderRadius:9,background:"var(--color-surface)",color:"inherit"};
const gridStyle={display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(190px,1fr))",gap:10,alignItems:"end"};

function SelectField({label,value,onChange,children}){return <label style={{display:"grid",gap:6}}><span>{label}</span><select style={inputStyle} value={value} onChange={onChange}>{children}</select></label>}
function InputField({label,...props}){return <label style={{display:"grid",gap:6}}><span>{label}</span><input style={inputStyle}{...props}/></label>}

export function InventoryWorkspace({canViewFinancials=true}){
  const[workspace,setWorkspace]=useState(emptyWorkspace);
  const[loading,setLoading]=useState(true);
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[busy,setBusy]=useState(false);
  const[search,setSearch]=useState("");
  const[transfer,setTransfer]=useState({item:"",source:"",destination:"",quantity:"",reason:""});
  const[adjustment,setAdjustment]=useState({item:"",warehouse:"",quantity:"",reason:""});
  const[count,setCount]=useState({warehouse:"",note:"",session:"",item:"",quantity:"",lineNote:"",postingReason:""});

  async function load(){
    setLoading(true);setError("");
    const{data,error}=await supabase.rpc("get_inventory_workspace");
    if(error)setError(friendlyError(error));else setWorkspace({...emptyWorkspace,...(data||{})});
    setLoading(false);
  }
  useEffect(()=>{void load()},[]);

  async function call(name,args,success){
    setBusy(true);setError("");setOk("");
    const{data,error}=await supabase.rpc(name,args);
    if(error)setError(friendlyError(error));else{setOk(success);await load()}
    setBusy(false);return data;
  }

  const balances=useMemo(()=>workspace.balances.filter(r=>`${r.item_name} ${r.sku||""} ${r.warehouse_name}`.toLowerCase().includes(search.toLowerCase())),[workspace,search]);
  const totals=useMemo(()=>workspace.balances.reduce((a,r)=>({qty:a.qty+Number(r.quantity_on_hand||0),value:a.value+Number(r.inventory_value||0)}),{qty:0,value:0}),[workspace]);
  const openSessions=(workspace.count_sessions||[]).filter(s=>["draft","submitted"].includes(s.status));
  const selectedSession=(workspace.count_sessions||[]).find(s=>s.id===count.session);
  const sessionLines=(workspace.count_lines||[]).filter(l=>l.session_id===count.session);
  const itemName=id=>(workspace.items||[]).find(i=>i.id===id)?.name||id;
  const warehouseName=id=>(workspace.warehouses||[]).find(w=>w.id===id)?.name||id;
  const sourceBalances=workspace.balances.filter(b=>!transfer.item||b.inventory_item_id===transfer.item).filter(b=>Number(b.quantity_on_hand)>0);

  async function submitTransfer(){
    if(!transfer.item||!transfer.source||!transfer.destination)return setError("اختر الصنف ومخزن المصدر ومخزن الوجهة");
    if(transfer.source===transfer.destination)return setError("مخزن المصدر والوجهة يجب أن يكونا مختلفين");
    if(Number(transfer.quantity)<=0)return setError("أدخل كمية تحويل أكبر من صفر");
    if(!transfer.reason.trim())return setError("اكتب سبب التحويل");
    await call("transfer_inventory",{target_inventory_item:transfer.item,source_warehouse:transfer.source,destination_warehouse:transfer.destination,transfer_quantity:Number(transfer.quantity),transfer_reason:transfer.reason.trim(),source_location:null,destination_location:null},"تم تحويل المخزون وتسجيل حركتي الخروج والدخول.");
    setTransfer({item:"",source:"",destination:"",quantity:"",reason:""});
  }
  async function submitAdjustment(){
    if(!adjustment.item||!adjustment.warehouse)return setError("اختر الصنف والمخزن");
    if(!Number(adjustment.quantity))return setError("أدخل فرقًا موجبًا للزيادة أو سالبًا للنقص");
    if(!adjustment.reason.trim())return setError("اكتب سبب التسوية");
    await call("adjust_inventory",{target_inventory_item:adjustment.item,target_warehouse:adjustment.warehouse,adjustment_quantity:Number(adjustment.quantity),adjustment_reason:adjustment.reason.trim(),target_location:null},"تم ترحيل التسوية إلى دفتر حركات المخزون.");
    setAdjustment({item:"",warehouse:"",quantity:"",reason:""});
  }
  async function createCount(){
    if(!count.warehouse)return setError("اختر مخزن الجرد");
    const data=await call("create_inventory_count_session",{target_warehouse:count.warehouse,session_note:count.note.trim()||null},"تم فتح جلسة جرد جديدة.");
    setCount(c=>({...c,session:data?.id||"",warehouse:"",note:""}));
  }
  async function saveCountLine(){
    if(!count.session||!count.item)return setError("اختر جلسة الجرد والصنف");
    if(count.quantity===""||Number(count.quantity)<0)return setError("أدخل الكمية الفعلية، ويمكن أن تكون صفرًا");
    await call("save_inventory_count_line",{target_session:count.session,target_inventory_item:count.item,target_counted_quantity:Number(count.quantity),line_note:count.lineNote.trim()||null},"تم حفظ كمية الجرد الفعلية.");
    setCount(c=>({...c,item:"",quantity:"",lineNote:""}));
  }
  async function postCount(){
    if(!count.session)return setError("اختر جلسة الجرد");
    if(!count.postingReason.trim())return setError("اكتب سبب اعتماد فروقات الجرد");
    if(!window.confirm("سيتم ترحيل فروقات الجرد إلى دفتر المخزون. متابعة؟"))return;
    await call("post_inventory_count_session",{target_session:count.session,posting_reason:count.postingReason.trim()},"تم اعتماد الجرد وترحيل الفروقات.");
    setCount(c=>({...c,session:"",postingReason:""}));
  }

  return <div>
    <h2>المخزون الفعلي</h2>
    <p style={{color:"var(--color-text-muted)"}}>الأرصدة أدناه من دفتر حركات المخزون المعتمد. لا يتم تعديل الرصيد مباشرة؛ كل فرق يسجل كحركة موثقة.</p>
    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
    {loading?<Notice>جارِ تحميل المخزون...</Notice>:<>
      <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(180px,1fr))",gap:12,marginBottom:16}}>
        <Panel title="الأصناف النشطة"><strong style={{fontSize:24}}>{workspace.items.length}</strong></Panel>
        <Panel title="إجمالي الكمية"><strong style={{fontSize:24}}>{money(totals.qty)}</strong></Panel>
        {canViewFinancials&&<Panel title="قيمة المخزون"><strong style={{fontSize:24}}>{money(totals.value)}</strong></Panel>}
      </div>

      {workspace.capabilities?.manage&&<>
        <WarehouseManagementPanel workspace={workspace} onChanged={load} canViewFinancials={canViewFinancials}/>
        <Panel title="تحويل بين المخازن">
          <div style={gridStyle}>
            <SelectField label="الصنف" value={transfer.item} onChange={e=>setTransfer({...transfer,item:e.target.value,source:""})}><option value="">اختر</option>{workspace.items.map(i=><option key={i.id} value={i.id}>{i.name}</option>)}</SelectField>
            <SelectField label="مخزن المصدر" value={transfer.source} onChange={e=>setTransfer({...transfer,source:e.target.value})}><option value="">اختر</option>{sourceBalances.map(b=><option key={b.warehouse_id} value={b.warehouse_id}>{b.warehouse_name} — متاح {money(b.quantity_on_hand)}</option>)}</SelectField>
            <SelectField label="مخزن الوجهة" value={transfer.destination} onChange={e=>setTransfer({...transfer,destination:e.target.value})}><option value="">اختر</option>{workspace.warehouses.map(w=><option key={w.id} value={w.id}>{w.name}</option>)}</SelectField>
            <InputField label="الكمية" type="number" min="0" step="any" value={transfer.quantity} onChange={e=>setTransfer({...transfer,quantity:e.target.value})}/>
            <InputField label="سبب التحويل" value={transfer.reason} onChange={e=>setTransfer({...transfer,reason:e.target.value})}/>
            <Button disabled={busy} onClick={submitTransfer}>تنفيذ التحويل</Button>
          </div>
        </Panel>

        <Panel title="تسوية موثقة">
          <p style={{color:"var(--color-text-muted)"}}>استخدم رقمًا موجبًا للزيادة وسالبًا للنقص. التسوية لا تحذف الحركة الأصلية.</p>
          <div style={gridStyle}>
            <SelectField label="الصنف" value={adjustment.item} onChange={e=>setAdjustment({...adjustment,item:e.target.value})}><option value="">اختر</option>{workspace.items.map(i=><option key={i.id} value={i.id}>{i.name}</option>)}</SelectField>
            <SelectField label="المخزن" value={adjustment.warehouse} onChange={e=>setAdjustment({...adjustment,warehouse:e.target.value})}><option value="">اختر</option>{workspace.warehouses.map(w=><option key={w.id} value={w.id}>{w.name}</option>)}</SelectField>
            <InputField label="فرق الكمية" type="number" step="any" value={adjustment.quantity} onChange={e=>setAdjustment({...adjustment,quantity:e.target.value})}/>
            <InputField label="سبب التسوية" value={adjustment.reason} onChange={e=>setAdjustment({...adjustment,reason:e.target.value})}/>
            <Button disabled={busy} onClick={submitAdjustment}>ترحيل التسوية</Button>
          </div>
        </Panel>

        <Panel title="الجرد الفعلي">
          <div style={gridStyle}>
            <SelectField label="فتح جرد لمخزن" value={count.warehouse} onChange={e=>setCount({...count,warehouse:e.target.value})}><option value="">اختر</option>{workspace.warehouses.map(w=><option key={w.id} value={w.id}>{w.name}</option>)}</SelectField>
            <InputField label="ملاحظة الجرد" value={count.note} onChange={e=>setCount({...count,note:e.target.value})}/>
            <Button disabled={busy} onClick={createCount}>فتح جلسة جرد</Button>
          </div>
          <hr style={{border:0,borderTop:"1px solid var(--color-border)",margin:"16px 0"}}/>
          <div style={gridStyle}>
            <SelectField label="جلسة مفتوحة" value={count.session} onChange={e=>setCount({...count,session:e.target.value})}><option value="">اختر</option>{openSessions.map(s=><option key={s.id} value={s.id}>{warehouseName(s.warehouse_id)} — {s.count_date}</option>)}</SelectField>
            <SelectField label="الصنف" value={count.item} onChange={e=>setCount({...count,item:e.target.value})}><option value="">اختر</option>{workspace.items.map(i=><option key={i.id} value={i.id}>{i.name}</option>)}</SelectField>
            <InputField label="الكمية الفعلية" type="number" min="0" step="any" value={count.quantity} onChange={e=>setCount({...count,quantity:e.target.value})}/>
            <InputField label="ملاحظة الصنف" value={count.lineNote} onChange={e=>setCount({...count,lineNote:e.target.value})}/>
            <Button disabled={busy||!count.session} onClick={saveCountLine}>حفظ الصنف</Button>
          </div>
          {selectedSession&&<div style={{marginTop:14}}><strong>بنود الجرد</strong>{sessionLines.map(l=><div key={l.id} style={{display:"flex",justifyContent:"space-between",gap:10,padding:"8px 0",borderBottom:"1px solid var(--color-border)"}}><span>{itemName(l.inventory_item_id)}</span><span>النظام {money(l.system_quantity)} — الفعلي {money(l.counted_quantity)} — الفرق {money(l.variance_quantity)}</span></div>)}{!sessionLines.length&&<p>لم تسجل أصناف في هذه الجلسة بعد.</p>}</div>}
          <div style={{...gridStyle,marginTop:14}}><InputField label="سبب اعتماد الفروقات" value={count.postingReason} onChange={e=>setCount({...count,postingReason:e.target.value})}/><Button disabled={busy||!count.session||!sessionLines.length} onClick={postCount}>اعتماد وترحيل الجرد</Button></div>
        </Panel>
      </>}

      <Panel title="الأرصدة" actions={<Button tone="ghost" onClick={load}>تحديث</Button>}>
        <input style={{...inputStyle,marginBottom:12}} value={search} onChange={e=>setSearch(e.target.value)} placeholder="ابحث باسم الصنف أو المخزن..."/>
        <div style={{overflowX:"auto"}}><table style={{width:"100%",borderCollapse:"collapse"}}><thead><tr>{["الصنف","المخزن","الوحدة","الرصيد",...(canViewFinancials?["متوسط التكلفة","القيمة"]:[])].map(h=><th key={h} style={{textAlign:"right",padding:9,borderBottom:"1px solid var(--color-border)"}}>{h}</th>)}</tr></thead><tbody>{balances.map(r=><tr key={`${r.inventory_item_id}-${r.warehouse_id}`}><td style={{padding:9}}>{r.item_name}</td><td>{r.warehouse_name}</td><td>{r.unit}</td><td>{money(r.quantity_on_hand)}</td>{canViewFinancials&&<><td>{money(r.average_unit_cost)}</td><td>{money(r.inventory_value)}</td></>}</tr>)}{!balances.length&&<tr><td colSpan={canViewFinancials?6:4} style={{padding:16,textAlign:"center"}}>لا توجد أرصدة مطابقة.</td></tr>}</tbody></table></div>
      </Panel>
      <Panel title="آخر حركات المخزون"><div style={{display:"grid",gap:8}}>{workspace.movements.slice(0,20).map(m=><div key={m.id} style={{padding:10,border:"1px solid var(--color-border)",borderRadius:9,display:"flex",justifyContent:"space-between",gap:10}}><span><strong>{m.item_name}</strong> — {m.warehouse_name}<small style={{display:"block",color:"var(--color-text-muted)"}}>{m.reason||m.movement_type}</small></span><span>{money(m.quantity_delta)}</span></div>)}{!workspace.movements.length&&<span>لا توجد حركات مخزون بعد.</span>}</div></Panel>
    </>}
  </div>;
}
