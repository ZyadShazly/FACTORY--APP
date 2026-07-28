import React,{useEffect,useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{Button,Notice,Panel,friendlyError,money}from"./ui";
import{WarehouseManagementPanel}from"./WarehouseManagementPanel";
import{InventoryCatalogPanel}from"./InventoryCatalogPanel";
import{OpeningInventoryPanel}from"./OpeningInventoryPanel";
import"./inventoryWorkspace.css";

const emptyWorkspace={items:[],catalog:[],materials:[],unlinked_materials:[],balances:[],warehouses:[],warehouse_admin:[],locations:[],movements:[],count_sessions:[],count_lines:[],opening_documents:[],opening_lines:[],capabilities:{}};
const inputStyle={width:"100%",padding:10,border:"1px solid var(--color-border)",borderRadius:9,background:"var(--color-surface)",color:"inherit"};
const gridStyle={display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(190px,1fr))",gap:10,alignItems:"end"};
const TABS=[
  {id:"items",label:"أصناف المخزون"},
  {id:"opening",label:"الرصيد الافتتاحي"},
  {id:"operations",label:"العمليات"},
  {id:"history",label:"السجل"},
  {id:"settings",label:"الإعدادات"},
];
const OPERATIONS=[
  {id:"receive",label:"استلام",description:"من أمر شراء معتمد"},
  {id:"issue",label:"صرف",description:"لأمر إنتاج مُصدر"},
  {id:"transfer",label:"تحويل",description:"بين مخزنين"},
  {id:"adjustment",label:"تسوية",description:"فرق موثق بالسبب"},
  {id:"count",label:"جرد",description:"جلسة وعدّ وترحيل"},
];

function SelectField({label,value,onChange,children}){return <label style={{display:"grid",gap:6}}><span>{label}</span><select style={inputStyle} value={value} onChange={onChange}>{children}</select></label>}
function InputField({label,...props}){return <label style={{display:"grid",gap:6}}><span>{label}</span><input style={inputStyle}{...props}/></label>}
function Kpi({label,value,alert=false}){return <div className={`inventory-kpi${alert?" is-alert":""}`}><span>{label}</span><strong>{value}</strong></div>}

export function InventoryWorkspace({canViewFinancials=true,onNavigate,allowedPages=[]}){
  const[workspace,setWorkspace]=useState(emptyWorkspace);
  const[loading,setLoading]=useState(true);
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[busy,setBusy]=useState(false);
  const[tab,setTab]=useState("items");
  const[operation,setOperation]=useState("receive");
  const[createRequest,setCreateRequest]=useState(0);
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

  const totals=useMemo(()=>workspace.balances.reduce((a,r)=>({qty:a.qty+Number(r.quantity_on_hand||0),value:a.value+Number(r.inventory_value||0)}),{qty:0,value:0}),[workspace]);
  const itemCount=(workspace.catalog||[]).length||(workspace.items||[]).length;
  const unlinkedCount=(workspace.unlinked_materials||[]).length;
  const openSessions=(workspace.count_sessions||[]).filter(s=>["draft","submitted"].includes(s.status));
  const selectedSession=(workspace.count_sessions||[]).find(s=>s.id===count.session);
  const sessionLines=(workspace.count_lines||[]).filter(l=>l.session_id===count.session);
  const itemName=id=>(workspace.items||[]).find(i=>i.id===id)?.name||id;
  const warehouseName=id=>(workspace.warehouses||[]).find(w=>w.id===id)?.name||id;
  const sourceBalances=workspace.balances.filter(b=>!transfer.item||b.inventory_item_id===transfer.item).filter(b=>Number(b.quantity_on_hand)>0);
  const canManage=Boolean(workspace.capabilities?.manage);
  const canOpenPurchases=allowedPages.includes("purchases");
  const canOpenProduction=allowedPages.includes("production");
  const canOpenMaterials=allowedPages.includes("materials");

  function openTab(nextTab,nextOperation=null){
    setTab(nextTab);
    if(nextOperation)setOperation(nextOperation);
    setError("");setOk("");
  }
  function newItem(){
    setTab("items");
    setCreateRequest(value=>value+1);
  }

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
    setCount(current=>({...current,session:data?.id||"",warehouse:"",note:""}));
  }
  async function saveCountLine(){
    if(!count.session||!count.item)return setError("اختر جلسة الجرد والصنف");
    if(count.quantity===""||Number(count.quantity)<0)return setError("أدخل الكمية الفعلية، ويمكن أن تكون صفرًا");
    await call("save_inventory_count_line",{target_session:count.session,target_inventory_item:count.item,target_counted_quantity:Number(count.quantity),line_note:count.lineNote.trim()||null},"تم حفظ كمية الجرد الفعلية.");
    setCount(current=>({...current,item:"",quantity:"",lineNote:""}));
  }
  async function postCount(){
    if(!count.session)return setError("اختر جلسة الجرد");
    if(!count.postingReason.trim())return setError("اكتب سبب اعتماد فروقات الجرد");
    if(!window.confirm("سيتم ترحيل فروقات الجرد إلى دفتر المخزون. متابعة؟"))return;
    await call("post_inventory_count_session",{target_session:count.session,posting_reason:count.postingReason.trim()},"تم اعتماد الجرد وترحيل الفروقات.");
    setCount(current=>({...current,session:"",postingReason:""}));
  }

  return <div className="inventory-workspace">
    <div className="inventory-hero">
      <div>
        <h2>مساحة عمل المخزون</h2>
        <p>الأصناف والإعدادات منفصلة عن الأرصدة الافتتاحية والعمليات والسجل. كل حركة ما زالت تمر عبر مسارها التشغيلي المحمي.</p>
      </div>
      <div className="inventory-primary-actions" aria-label="إجراءات المخزون الأساسية">
        <Button disabled={!canManage} onClick={newItem}>+ صنف مخزون جديد</Button>
        <Button disabled={!canManage} onClick={()=>openTab("opening")}>+ رصيد افتتاحي</Button>
        <Button onClick={()=>openTab("operations","receive")}>+ استلام</Button>
        <Button onClick={()=>openTab("operations","issue")}>+ صرف</Button>
      </div>
    </div>

    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
    {loading?<Notice>جارِ تحميل المخزون...</Notice>:<>
      <div className="inventory-kpis" aria-label="ملخص المخزون">
        <Kpi label="أصناف المخزون" value={itemCount.toLocaleString("ar-EG")}/>
        <Kpi label="قيمة المخزون" value={canViewFinancials?money(totals.value):"محجوبة"}/>
        <Kpi label="إجمالي الكمية" value={money(totals.qty)}/>
        <Kpi label="مواد خام غير مربوطة" value={unlinkedCount.toLocaleString("ar-EG")} alert={unlinkedCount>0}/>
      </div>

      <nav className="inventory-tabs" aria-label="أقسام مساحة المخزون">
        {TABS.map(item=><button key={item.id} type="button" aria-selected={tab===item.id} onClick={()=>openTab(item.id)}>{item.label}</button>)}
      </nav>

      {tab==="items"&&<InventoryCatalogPanel workspace={workspace} onChanged={load} onOpenMaterials={canOpenMaterials&&onNavigate?()=>onNavigate("materials"):null} canManage={canManage} createRequest={createRequest}/>}

      {tab==="opening"&&(canManage
        ?<OpeningInventoryPanel workspace={workspace} onChanged={load} canViewFinancials={canViewFinancials}/>
        :<Notice>لا توجد صلاحية لإدارة مستندات الرصيد الافتتاحي.</Notice>)}

      {tab==="operations"&&<section>
        <div className="inventory-section-heading"><div><h3>عمليات المخزون</h3><p>اختر العملية المطلوبة فقط؛ لن تظهر النماذج الأخرى في نفس الوقت.</p></div></div>
        <div className="inventory-operation-grid">
          {OPERATIONS.map(item=><button key={item.id} type="button" className="inventory-operation-card" aria-pressed={operation===item.id} disabled={!canManage&&!["receive","issue"].includes(item.id)} onClick={()=>setOperation(item.id)}><strong>{item.label}</strong><small>{item.description}</small></button>)}
        </div>

        {operation==="receive"&&<div className="inventory-route-card">
          <h4>استلام المخزون</h4>
          <p>الاستلام يظل مرتبطًا بأمر شراء معتمد، ويُرحّل من شاشة المشتريات إلى دفتر المخزون في عملية واحدة.</p>
          <div><Button disabled={!canOpenPurchases||!onNavigate} onClick={()=>onNavigate?.("purchases")}>فتح المشتريات والاستلام</Button></div>
          {!canOpenPurchases&&<small>هذه الصفحة غير متاحة ضمن صلاحيات الحساب الحالي.</small>}
        </div>}

        {operation==="issue"&&<div className="inventory-route-card">
          <h4>صرف المخزون</h4>
          <p>صرف الخامات يظل مرتبطًا بمتطلبات أمر إنتاج مُصدر حتى لا يتم تجاوز الحجز أو احتساب التكلفة مرتين.</p>
          <div><Button disabled={!canOpenProduction||!onNavigate} onClick={()=>onNavigate?.("production")}>فتح أوامر الإنتاج والصرف</Button></div>
          {!canOpenProduction&&<small>هذه الصفحة غير متاحة ضمن صلاحيات الحساب الحالي.</small>}
        </div>}

        {operation==="transfer"&&canManage&&<Panel title="تحويل بين المخازن">
          <div style={gridStyle}>
            <SelectField label="الصنف" value={transfer.item} onChange={e=>setTransfer({...transfer,item:e.target.value,source:""})}><option value="">اختر</option>{workspace.items.map(i=><option key={i.id} value={i.id}>{i.name}</option>)}</SelectField>
            <SelectField label="مخزن المصدر" value={transfer.source} onChange={e=>setTransfer({...transfer,source:e.target.value})}><option value="">اختر</option>{sourceBalances.map(b=><option key={b.warehouse_id} value={b.warehouse_id}>{b.warehouse_name} — متاح {money(b.quantity_on_hand)}</option>)}</SelectField>
            <SelectField label="مخزن الوجهة" value={transfer.destination} onChange={e=>setTransfer({...transfer,destination:e.target.value})}><option value="">اختر</option>{workspace.warehouses.map(w=><option key={w.id} value={w.id}>{w.name}</option>)}</SelectField>
            <InputField label="الكمية" type="number" min="0" step="any" value={transfer.quantity} onChange={e=>setTransfer({...transfer,quantity:e.target.value})}/>
            <InputField label="سبب التحويل" value={transfer.reason} onChange={e=>setTransfer({...transfer,reason:e.target.value})}/>
            <Button disabled={busy} onClick={submitTransfer}>تنفيذ التحويل</Button>
          </div>
        </Panel>}

        {operation==="adjustment"&&canManage&&<Panel title="تسوية موثقة">
          <p style={{color:"var(--color-text-muted)"}}>استخدم رقمًا موجبًا للزيادة وسالبًا للنقص. التسوية لا تحذف الحركة الأصلية.</p>
          <div style={gridStyle}>
            <SelectField label="الصنف" value={adjustment.item} onChange={e=>setAdjustment({...adjustment,item:e.target.value})}><option value="">اختر</option>{workspace.items.map(i=><option key={i.id} value={i.id}>{i.name}</option>)}</SelectField>
            <SelectField label="المخزن" value={adjustment.warehouse} onChange={e=>setAdjustment({...adjustment,warehouse:e.target.value})}><option value="">اختر</option>{workspace.warehouses.map(w=><option key={w.id} value={w.id}>{w.name}</option>)}</SelectField>
            <InputField label="فرق الكمية" type="number" step="any" value={adjustment.quantity} onChange={e=>setAdjustment({...adjustment,quantity:e.target.value})}/>
            <InputField label="سبب التسوية" value={adjustment.reason} onChange={e=>setAdjustment({...adjustment,reason:e.target.value})}/>
            <Button disabled={busy} onClick={submitAdjustment}>ترحيل التسوية</Button>
          </div>
        </Panel>}

        {operation==="count"&&canManage&&<Panel title="الجرد الفعلي">
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
          {selectedSession&&<div style={{marginTop:14}}><strong>بنود الجرد</strong>{sessionLines.map(line=><div key={line.id} className="inventory-history-row"><span>{itemName(line.inventory_item_id)}</span><span>النظام {money(line.system_quantity)} — الفعلي {money(line.counted_quantity)} — الفرق {money(line.variance_quantity)}</span></div>)}{!sessionLines.length&&<p>لم تسجل أصناف في هذه الجلسة بعد.</p>}</div>}
          <div style={{...gridStyle,marginTop:14}}><InputField label="سبب اعتماد الفروقات" value={count.postingReason} onChange={e=>setCount({...count,postingReason:e.target.value})}/><Button disabled={busy||!count.session||!sessionLines.length} onClick={postCount}>اعتماد وترحيل الجرد</Button></div>
        </Panel>}
      </section>}

      {tab==="history"&&<Panel title="سجل حركات المخزون" actions={<Button tone="ghost" onClick={load}>تحديث</Button>}>
        <div className="inventory-history-list">{workspace.movements.slice(0,100).map(movement=><div key={movement.id} className="inventory-history-row"><span><strong>{movement.item_name}</strong> — {movement.warehouse_name}<small>{movement.reason||movement.movement_type}</small></span><strong>{money(movement.quantity_delta)}</strong></div>)}{!workspace.movements.length&&<div className="inventory-empty">لا توجد حركات مخزون بعد.</div>}</div>
      </Panel>}

      {tab==="settings"&&(canManage
        ?<WarehouseManagementPanel workspace={workspace} onChanged={load} canViewFinancials={canViewFinancials}/>
        :<Notice>لا توجد صلاحية لإدارة المخازن ومواقع التخزين.</Notice>)}
    </>}
  </div>;
}
