import React,{useEffect,useState}from"react";
import{supabase}from"../supabaseClient";
import{Button,Field,Notice,Panel,dateText,friendlyError,inputStyle,money}from"./ui";

const STATUS={draft:"مسودة",planned:"مخطط",released:"مُصدر",in_progress:"قيد التنفيذ",completed:"مكتمل",cancelled:"ملغي",pending:"معلق",ready:"جاهز",skipped:"متجاوز"};

function materialState(required,issued){
  const need=Number(required||0);
  const done=Number(issued||0);
  if(done<=0)return{label:"لم يبدأ",tone:"var(--color-text-muted)"};
  if(done<need)return{label:"صرف جزئي",tone:"#a16207"};
  return{label:"مكتمل",tone:"#15803d"};
}

export function ProductionWorkspace({data,profileRole,canViewFinancials=true}){
  const[workspace,setWorkspace]=useState({orders:[],operations:[],requirements:[],capabilities:{}});
  const[inventory,setInventory]=useState({warehouses:[]});
  const[form,setForm]=useState({product:"",project:"",warehouse:"",qty:"",waste:"0",date:new Date().toISOString().slice(0,10)});
  const[issueQty,setIssueQty]=useState({});
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[loading,setLoading]=useState(true);

  async function load(){
    setLoading(true);setError("");
    const[p,i]=await Promise.all([supabase.rpc("get_production_workspace"),supabase.rpc("get_inventory_workspace")]);
    if(p.error)setError(friendlyError(p.error));else setWorkspace(p.data||{orders:[],operations:[],requirements:[],capabilities:{}});
    if(!i.error)setInventory(i.data||{warehouses:[]});
    setLoading(false);
  }

  useEffect(()=>{void load()},[]);

  async function call(name,args,success){
    setError("");setOk("");
    const{error}=await supabase.rpc(name,args);
    if(error)return setError(friendlyError(error));
    setOk(success);await load();
  }

  async function create(){
    if(!form.product)return setError("اختر المنتج");
    if(Number(form.qty)<=0)return setError("أدخل كمية أكبر من صفر");
    await call("create_production_order_secure",{target_product:form.product,target_quantity:Number(form.qty),target_waste_percentage:Number(form.waste||0),target_project:form.project||null,target_warehouse:form.warehouse||null,target_order_date:form.date,target_note:null},"تم إنشاء أمر الإنتاج ومتطلبات خاماته من BOM.");
  }

  async function issueMaterial(requirement){
    const remaining=Math.max(0,Number(requirement.required_quantity)-Number(requirement.issued_quantity));
    const quantity=Number(issueQty[requirement.id]??remaining);
    if(!Number.isFinite(quantity)||quantity<=0)return setError("أدخل كمية صرف أكبر من صفر.");
    if(quantity>remaining)return setError(`الكمية المدخلة أكبر من المتبقي (${remaining} ${requirement.inventory_item_unit||""}).`);
    await call("issue_production_material",{target_requirement:requirement.id,issue_quantity:quantity,issue_description:"صرف جزئي لخامات أمر إنتاج"},"تم صرف الدفعة وتحديث المصروف والمتبقي.");
    setIssueQty(current=>({...current,[requirement.id]:""}));
  }

  const opsFor=id=>workspace.operations.filter(x=>x.production_order_id===id);
  const reqFor=id=>workspace.requirements.filter(x=>x.production_order_id===id);

  return <div>
    <h2>أوامر الإنتاج</h2>
    <p style={{color:"var(--color-text-muted)"}}>اصرف الخامات على دفعات، وتابع المطلوب والمصروف والمتبقي لكل خامة بدون إغلاق الأمر بعد أول حركة.</p>
    {error&&<Notice type="error">{error}</Notice>}
    {ok&&<Notice>{ok}</Notice>}

    {workspace.capabilities.create&&<Panel title="أمر إنتاج جديد">
      <div style={{display:"flex",gap:10,flexWrap:"wrap",alignItems:"end"}}>
        <Field label="المنتج"><select style={inputStyle} value={form.product} onChange={e=>setForm({...form,product:e.target.value})}><option value="">اختر</option>{data.products.map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select></Field>
        <Field label="المشروع"><select style={inputStyle} value={form.project} onChange={e=>setForm({...form,project:e.target.value})}><option value="">اختر</option>{data.projects.map(p=><option key={p.id} value={p.id}>{p.project_name||p.name||p.project_code}</option>)}</select></Field>
        <Field label="المخزن"><select style={inputStyle} value={form.warehouse} onChange={e=>setForm({...form,warehouse:e.target.value})}><option value="">اختر</option>{inventory.warehouses.map(w=><option key={w.id} value={w.id}>{w.name}</option>)}</select></Field>
        <Field label="الكمية"><input type="number" style={inputStyle} value={form.qty} onChange={e=>setForm({...form,qty:e.target.value})}/></Field>
        <Field label="الهالك %"><input type="number" style={inputStyle} value={form.waste} onChange={e=>setForm({...form,waste:e.target.value})}/></Field>
        <Field label="التاريخ"><input type="date" style={inputStyle} value={form.date} onChange={e=>setForm({...form,date:e.target.value})}/></Field>
        <Button onClick={create}>إنشاء الأمر</Button>
      </div>
    </Panel>}

    {loading?<Notice>جارِ تحميل أوامر الإنتاج...</Notice>:workspace.orders.map(o=>{
      const requirements=reqFor(o.id);
      const incomplete=requirements.filter(r=>Number(r.issued_quantity)<Number(r.required_quantity));
      return <Panel key={o.id} title={`${o.product_name||"منتج"} — ${STATUS[o.status]||o.status}`} actions={<span>{o.project_name||"بدون مشروع"}</span>}>
        <div style={{display:"flex",gap:14,flexWrap:"wrap",marginBottom:12}}>
          <span>الكمية: <strong>{o.qty}</strong></span><span>التاريخ: {dateText(o.order_date)}</span>{canViewFinancials&&<span>التكلفة: {money(o.total_cost)}</span>}
          {incomplete.length>0&&["released","in_progress"].includes(o.status)&&<span style={{color:"#a16207",fontWeight:700}}>خامات ناقصة: {incomplete.length}</span>}
        </div>
        <div style={{display:"flex",gap:8,flexWrap:"wrap",marginBottom:12}}>
          {workspace.capabilities.plan&&["draft","planned"].includes(o.status)&&<Button onClick={()=>call("plan_production_order",{target_order:o.id,start_date:new Date().toISOString().slice(0,10),end_date:null},"تم تخطيط الأمر.")}>تخطيط</Button>}
          {workspace.capabilities.release&&o.status==="planned"&&<Button onClick={()=>call("release_production_order",{target_order:o.id},"تم إصدار الأمر.")}>إصدار</Button>}
          {workspace.capabilities.complete&&o.status==="in_progress"&&<Button onClick={()=>call("complete_production_order",{target_order:o.id},"تم إكمال أمر الإنتاج.")}>إكمال الأمر</Button>}
          {profileRole==="owner"&&!['completed','cancelled'].includes(o.status)&&<Button tone="danger" onClick={()=>call("cancel_production_order",{target_order:o.id,reason:"إلغاء إداري من شاشة الإنتاج"},"تم إلغاء الأمر وعكس الحركات المرتبطة.")}>إلغاء وعكس</Button>}
        </div>
        <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(280px,1fr))",gap:12}}>
          <div>
            <strong>الخامات المطلوبة</strong>
            {requirements.map(r=>{
              const required=Number(r.required_quantity||0);
              const issued=Number(r.issued_quantity||0);
              const remaining=Math.max(0,required-issued);
              const state=materialState(required,issued);
              const percent=required?Math.min(100,Math.round((issued/required)*100)):0;
              return <div key={r.id} style={{padding:"12px 0",borderBottom:"1px solid var(--color-border)"}}>
                <div style={{display:"flex",justifyContent:"space-between",gap:8,alignItems:"center"}}><strong>{r.inventory_item_name}</strong><span style={{color:state.tone,fontWeight:700}}>{state.label}</span></div>
                <div style={{display:"grid",gridTemplateColumns:"repeat(3,1fr)",gap:8,marginTop:8,fontSize:13}}>
                  <span>المطلوب<br/><strong>{required}</strong></span><span>المصروف<br/><strong>{issued}</strong></span><span>المتبقي<br/><strong>{remaining}</strong></span>
                </div>
                <div style={{height:6,background:"var(--color-border)",borderRadius:99,overflow:"hidden",marginTop:8}}><div style={{height:"100%",width:`${percent}%`,background:state.tone}}/></div>
                {workspace.capabilities.issue&&["released","in_progress"].includes(o.status)&&remaining>0&&<div style={{display:"flex",gap:8,alignItems:"end",marginTop:10,flexWrap:"wrap"}}>
                  <Field label={`صرف الآن (${r.inventory_item_unit||"وحدة"})`}><input type="number" min="0.0001" max={remaining} step="any" style={{...inputStyle,width:130}} value={issueQty[r.id]??""} placeholder={String(remaining)} onChange={e=>setIssueQty(current=>({...current,[r.id]:e.target.value}))}/></Field>
                  <Button onClick={()=>issueMaterial(r)}>تسجيل الصرف</Button>
                </div>}
              </div>;
            })}
            {!requirements.length&&<p>لا توجد خامات.</p>}
          </div>
          <div>
            <strong>خطوات التشغيل</strong>
            {opsFor(o.id).map(op=><div key={op.id} style={{padding:"8px 0",borderBottom:"1px solid var(--color-border)"}}>{op.name}: {STATUS[op.status]||op.status}<div style={{display:"flex",gap:6,marginTop:6}}>{workspace.capabilities.operate&&op.status==="pending"&&<Button onClick={()=>call("update_production_operation_status",{target_operation:op.id,target_status:"ready",actual_minutes:null,operation_note:null},"تم تجهيز الخطوة.")}>جاهز</Button>}{workspace.capabilities.operate&&op.status==="ready"&&<Button onClick={()=>call("update_production_operation_status",{target_operation:op.id,target_status:"in_progress",actual_minutes:null,operation_note:null},"بدأت الخطوة.")}>بدء</Button>}{workspace.capabilities.operate&&op.status==="in_progress"&&<Button onClick={()=>call("update_production_operation_status",{target_operation:op.id,target_status:"completed",actual_minutes:null,operation_note:null},"اكتملت الخطوة.")}>إكمال</Button>}</div></div>)}
          </div>
        </div>
      </Panel>;
    })}
    {!loading&&!workspace.orders.length&&<Notice>لا توجد أوامر إنتاج.</Notice>}
  </div>;
}
