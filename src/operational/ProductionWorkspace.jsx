import React,{useEffect,useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{
  ArchiveSection,Button,DetailsDrawer,Field,HelpText,KpiCard,KpiGrid,Notice,
  PageHeader,PrimaryActionBar,SearchFilterBar,StatusBadge,dateText,friendlyError,
  inputStyle,money
}from"./ui";
import"./productionWorkspace.css";

const emptyWorkspace={orders:[],operations:[],requirements:[],events:[],employees:[],capabilities:{}};
const STATUS={
  draft:"مسودة",planned:"مخطط",released:"مُصدر",in_progress:"قيد التنفيذ",
  completed:"مكتمل",cancelled:"ملغي",pending:"معلق",ready:"جاهز",skipped:"متجاوز"
};
const QUALITY={pending:"لم يُرسل",awaiting_review:"بانتظار الجودة",approved:"معتمد",rejected:"مرفوض"};
const ACTIVE_ORDER=new Set(["draft","planned","released","in_progress"]);
const finishBlank={accepted:"",rejected:"0",rework:"0",reason:""};

function orderReference(order){return `PROD-${String(order.id||"").slice(0,8).toUpperCase()}`}
function ratio(done,total){return total?Math.min(100,Math.round((done/total)*100)):100}
function Progress({label,value}){
  return <div className="production-progress"><span>{label}</span><strong>{value}%</strong><div><i style={{width:`${value}%`}}/></div></div>;
}

export function ProductionWorkspace({data,profileRole,canViewFinancials=true}){
  const[workspace,setWorkspace]=useState(emptyWorkspace);
  const[inventory,setInventory]=useState({warehouses:[]});
  const[form,setForm]=useState({product:"",project:"",warehouse:"",qty:"",waste:"0",date:new Date().toISOString().slice(0,10)});
  const[creating,setCreating]=useState(false);
  const[selectedId,setSelectedId]=useState("");
  const[issueQty,setIssueQty]=useState({});
  const[assignments,setAssignments]=useState({});
  const[finishing,setFinishing]=useState(null);
  const[finishForm,setFinishForm]=useState(finishBlank);
  const[search,setSearch]=useState("");
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[busy,setBusy]=useState("");
  const[loading,setLoading]=useState(true);

  async function load(){
    setLoading(true);setError("");
    const[p,i]=await Promise.all([supabase.rpc("get_production_workspace"),supabase.rpc("get_inventory_workspace")]);
    if(p.error)setError(friendlyError(p.error));else setWorkspace({...emptyWorkspace,...(p.data||{})});
    if(!i.error)setInventory(i.data||{warehouses:[]});
    setLoading(false);
  }
  useEffect(()=>{void load()},[]);

  async function call(key,name,args,success){
    setBusy(key);setError("");setOk("");
    const{data:result,error:callError}=await supabase.rpc(name,args);
    if(callError){setError(friendlyError(callError));setBusy("");return false}
    setOk(success);await load();setBusy("");return result||true;
  }

  async function create(){
    if(!form.product)return setError("اختر المنتج.");
    if(Number(form.qty)<=0)return setError("أدخل كمية إنتاج أكبر من صفر.");
    const result=await call("create","create_production_order_secure",{
      target_product:form.product,target_quantity:Number(form.qty),
      target_waste_percentage:Number(form.waste||0),target_project:form.project||null,
      target_warehouse:form.warehouse||null,target_order_date:form.date,target_note:null
    },"تم إنشاء أمر الإنتاج كمسودة مع متطلبات خاماته وخطوة تشغيله.");
    if(result){setCreating(false);setForm(current=>({...current,product:"",project:"",warehouse:"",qty:"",waste:"0"}))}
  }

  async function issueMaterial(requirement){
    const remaining=Math.max(0,Number(requirement.required_quantity)-Number(requirement.issued_quantity));
    const quantity=Number(issueQty[requirement.id]??remaining);
    if(!Number.isFinite(quantity)||quantity<=0)return setError("أدخل كمية صرف أكبر من صفر.");
    if(quantity>remaining)return setError(`الكمية المدخلة أكبر من المتبقي (${remaining} ${requirement.inventory_item_unit||""}).`);
    const result=await call(requirement.id,"issue_production_material",{
      target_requirement:requirement.id,issue_quantity:quantity,
      issue_description:`صرف دفعة خامات ${requirement.inventory_item_name||""}`.trim()
    },"تم صرف الدفعة وتحديث المصروف والمتبقي مع حفظ حركتها.");
    if(result)setIssueQty(current=>({...current,[requirement.id]:""}));
  }

  async function assignOperation(operation){
    const employeeId=assignments[operation.id]??operation.assigned_employee_id??"";
    if(!employeeId)return setError("اختر الموظف المسؤول عن خطوة التشغيل.");
    await call(operation.id,"assign_production_operation",{
      target_operation:operation.id,target_employee:employeeId
    },"تم إسناد خطوة التشغيل وتسجيل الحدث.");
  }

  async function readyOperation(operation){
    await call(operation.id,"update_production_operation_status",{
      target_operation:operation.id,target_status:"ready",actual_minutes:null,operation_note:null
    },"الخطوة جاهزة للبدء.");
  }

  async function operationEvent(operation,event,reason=null){
    await call(operation.id,"record_production_operation_event",{
      target_operation:operation.id,target_event:event,event_reason:reason,
      good_quantity:null,bad_quantity:null,rework_qty:null
    },{
      start:"بدأ تنفيذ الخطوة.",pause:"تم إيقاف الخطوة مؤقتًا وتسجيل السبب.",
      resume:"تم استئناف الخطوة."
    }[event]);
  }

  async function pauseOperation(operation){
    const reason=window.prompt("اكتب سبب إيقاف خطوة التشغيل مؤقتًا.");
    if(reason===null)return;
    if(!reason.trim())return setError("سبب الإيقاف المؤقت مطلوب.");
    await operationEvent(operation,"pause",reason.trim());
  }

  function openFinish(operation,order){
    setFinishing(operation);
    setFinishForm({accepted:String(order.qty||""),rejected:"0",rework:"0",reason:""});
  }

  async function finishOperation(){
    const accepted=Number(finishForm.accepted),rejected=Number(finishForm.rejected),rework=Number(finishForm.rework);
    if([accepted,rejected,rework].some(value=>!Number.isFinite(value)||value<0))return setError("أدخل كميات صحيحة غير سالبة.");
    if((rejected>0||rework>0)&&!finishForm.reason.trim())return setError("سبب الرفض أو إعادة التشغيل مطلوب.");
    const result=await call(finishing.id,"record_production_operation_event",{
      target_operation:finishing.id,target_event:"complete",
      event_reason:finishForm.reason.trim()||null,good_quantity:accepted,
      bad_quantity:rejected,rework_qty:rework
    },"اكتملت الخطوة وأُرسلت لمراجعة الجودة.");
    if(result){setFinishing(null);setFinishForm(finishBlank)}
  }

  async function reviewQuality(operation,approve){
    let reason=null;
    if(!approve){
      reason=window.prompt("اكتب سبب رفض مراجعة الجودة وما المطلوب تصحيحه.");
      if(reason===null)return;
      if(!reason.trim())return setError("سبب رفض الجودة مطلوب.");
    }
    await call(operation.id,"review_production_operation_quality",{
      target_operation:operation.id,approve,review_reason:reason?.trim()||null
    },approve?"تم اعتماد جودة خطوة التشغيل.":"تم رفض الجودة مع حفظ السبب.");
  }

  async function skipOperation(operation){
    const reason=window.prompt("اكتب سبب تجاوز خطوة التشغيل. سيبقى القرار محفوظًا في التدقيق.");
    if(reason===null)return;
    if(!reason.trim())return setError("سبب تجاوز الخطوة مطلوب.");
    await call(operation.id,"update_production_operation_status",{
      target_operation:operation.id,target_status:"skipped",
      actual_minutes:null,operation_note:reason.trim()
    },"تم تجاوز الخطوة بقرار إداري موثق.");
  }

  async function cancelOrder(order){
    const reason=window.prompt(`اكتب سبب إلغاء ${orderReference(order)}. ستُعكس حركات الصرف المؤهلة دون حذف التاريخ.`);
    if(reason===null)return;
    if(!reason.trim())return setError("سبب إلغاء أمر الإنتاج مطلوب.");
    await call(order.id,"cancel_production_order",{target_order:order.id,reason:reason.trim()},"تم إلغاء الأمر وعكس الحركات المؤهلة مع حفظ التاريخ.");
  }

  const reqFor=id=>workspace.requirements.filter(row=>row.production_order_id===id);
  const opsFor=id=>workspace.operations.filter(row=>row.production_order_id===id);
  const eventsFor=id=>workspace.events.filter(row=>row.operation_id===id);
  const metrics=order=>{
    const requirements=reqFor(order.id),operations=opsFor(order.id);
    const required=requirements.reduce((sum,row)=>sum+Number(row.required_quantity||0),0);
    const issued=requirements.reduce((sum,row)=>sum+Number(row.issued_quantity||0),0);
    const completed=operations.filter(row=>["completed","skipped"].includes(row.status)).length;
    const qualityPending=operations.filter(row=>row.status==="completed"&&row.quality_status!=="approved").length;
    return{
      requirements,operations,materialProgress:ratio(issued,required),
      operationProgress:ratio(completed,operations.length),
      materialsComplete:requirements.length>0&&requirements.every(row=>Number(row.issued_quantity)>=Number(row.required_quantity)),
      operationsComplete:operations.every(row=>["completed","skipped"].includes(row.status)),
      qualityComplete:operations.filter(row=>row.status==="completed").every(row=>row.quality_status==="approved"),
      qualityPending
    };
  };
  const nextAction=(order,m)=>{
    if(order.status==="draft")return"تخطيط الأمر";
    if(order.status==="planned")return"إصدار الأمر";
    if(!m.materialsComplete)return"استكمال صرف الخامات";
    if(!m.operationsComplete)return"استكمال خطوات التشغيل";
    if(!m.qualityComplete)return"مراجعة الجودة";
    if(order.status==="in_progress")return"إكمال أمر الإنتاج";
    return"مراجعة السجل";
  };
  const matches=order=>`${orderReference(order)} ${order.product_name||""} ${order.project_name||""} ${STATUS[order.status]||order.status}`.toLowerCase().includes(search.trim().toLowerCase());
  const activeOrders=useMemo(()=>workspace.orders.filter(order=>ACTIVE_ORDER.has(order.status)&&matches(order)),[workspace.orders,search]);
  const historicalOrders=useMemo(()=>workspace.orders.filter(order=>!ACTIVE_ORDER.has(order.status)&&matches(order)),[workspace.orders,search]);
  const selected=workspace.orders.find(order=>order.id===selectedId)||null;
  const selectedMetrics=selected?metrics(selected):null;
  const runningOperations=workspace.operations.filter(operation=>operation.status==="in_progress"&&!operation.paused_at).length;
  const pendingQuality=workspace.operations.filter(operation=>operation.quality_status==="awaiting_review").length;
  const shortageOrders=workspace.orders.filter(order=>ACTIVE_ORDER.has(order.status)&&!metrics(order).materialsComplete).length;

  const orderCard=order=>{
    const m=metrics(order);
    return <article className="production-order-card" key={order.id}>
      <div className="production-order-identity">
        <strong>{order.product_name||"منتج غير مسمى"}</strong>
        <small>{orderReference(order)} · {order.project_name||"بدون مشروع"}</small>
      </div>
      <StatusBadge label={STATUS[order.status]||order.status} tone={order.status==="cancelled"?"danger":order.status==="completed"?"success":"info"}/>
      <div className="production-card-progress">
        <Progress label="الخامات" value={m.materialProgress}/>
        <Progress label="التشغيل" value={m.operationProgress}/>
      </div>
      <div className="production-next"><span>الخطوة التالية</span><strong>{nextAction(order,m)}</strong></div>
      <Button tone="ghost" onClick={()=>setSelectedId(order.id)}>فتح التفاصيل</Button>
    </article>;
  };

  return <div className="production-workspace">
    <PageHeader eyebrow="المصنع والتنفيذ" title="أوامر الإنتاج" description="تابع أمرًا واحدًا من التخطيط إلى صرف الخامات والتنفيذ والجودة والإكمال، مع إبقاء التاريخ على الطلب."/>
    <PrimaryActionBar primaryAction={workspace.capabilities.create?<Button onClick={()=>setCreating(value=>!value)}>+ أمر إنتاج جديد</Button>:null}>
      <span>الأوامر النشطة أولًا، والمكتملة والملغاة محفوظة في السجل.</span>
    </PrimaryActionBar>

    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
    <KpiGrid>
      <KpiCard label="أوامر نشطة" value={activeOrders.length}/>
      <KpiCard label="عمليات تعمل الآن" value={runningOperations}/>
      <KpiCard label="أوامر تحتاج خامات" value={shortageOrders}/>
      <KpiCard label="بانتظار الجودة" value={pendingQuality}/>
    </KpiGrid>

    {creating&&workspace.capabilities.create&&<section className="production-create">
      <h3>مسودة أمر إنتاج جديد</h3>
      <HelpText title="قبل الإنشاء">اربط المنتج بتركيبة خامات نشطة واختر المخزن. الإنشاء لا يصرف مخزونًا حتى إصدار الأمر وتسجيل كل دفعة.</HelpText>
      <div className="production-form-grid">
        <Field label="المنتج"><select style={inputStyle} value={form.product} onChange={event=>setForm({...form,product:event.target.value})}><option value="">اختر</option>{(data.products||[]).filter(row=>!row.archived_at).map(row=><option key={row.id} value={row.id}>{row.name}</option>)}</select></Field>
        <Field label="المشروع"><select style={inputStyle} value={form.project} onChange={event=>setForm({...form,project:event.target.value})}><option value="">اختر</option>{(data.projects||[]).map(row=><option key={row.id} value={row.id}>{row.project_name||row.name||row.project_code}</option>)}</select></Field>
        <Field label="المخزن"><select style={inputStyle} value={form.warehouse} onChange={event=>setForm({...form,warehouse:event.target.value})}><option value="">اختر</option>{(inventory.warehouses||[]).map(row=><option key={row.id} value={row.id}>{row.name}</option>)}</select></Field>
        <Field label="الكمية"><input type="number" min="0" style={inputStyle} value={form.qty} onChange={event=>setForm({...form,qty:event.target.value})}/></Field>
        <Field label="الهالك %"><input type="number" min="0" style={inputStyle} value={form.waste} onChange={event=>setForm({...form,waste:event.target.value})}/></Field>
        <Field label="التاريخ"><input type="date" style={inputStyle} value={form.date} onChange={event=>setForm({...form,date:event.target.value})}/></Field>
        <Button disabled={busy==="create"} onClick={create}>حفظ المسودة</Button>
      </div>
    </section>}

    <SearchFilterBar value={search} onChange={event=>setSearch(event.target.value)} placeholder="ابحث برقم الأمر أو المنتج أو المشروع أو الحالة"/>
    {loading?<Notice>جاري تحميل أوامر الإنتاج...</Notice>:<>
      <section>
        <h3>الأوامر النشطة ({activeOrders.length})</h3>
        <div className="production-order-list">{activeOrders.map(orderCard)}{!activeOrders.length&&<Notice>لا توجد أوامر إنتاج نشطة مطابقة.</Notice>}</div>
      </section>
      <ArchiveSection title="سجل الأوامر المكتملة والملغاة" count={historicalOrders.length}>
        <div className="production-order-list">{historicalOrders.map(orderCard)}</div>
      </ArchiveSection>
    </>}

    <DetailsDrawer open={Boolean(selected)&&!finishing} title={selected?`${selected.product_name||"أمر إنتاج"} · ${orderReference(selected)}`:""} description={selected?`${selected.project_name||"بدون مشروع"} · ${STATUS[selected.status]||selected.status}`:""} onClose={()=>{setSelectedId("");setFinishing(null)}} className="production-details-drawer">
      {selected&&selectedMetrics&&<>
        <div className="production-detail-summary">
          <Progress label="تقدم الخامات" value={selectedMetrics.materialProgress}/>
          <Progress label="تقدم التشغيل" value={selectedMetrics.operationProgress}/>
          <span>الكمية <strong>{selected.qty}</strong></span>
          <span>التاريخ <strong>{dateText(selected.order_date)}</strong></span>
          {canViewFinancials&&workspace.capabilities.view_financials&&<>
            <span>التكلفة المخططة <strong>{money(selected.total_cost)}</strong></span>
            <span>تكلفة الخامات الفعلية <strong>{money(selected.actual_material_cost)}</strong></span>
          </>}
        </div>
        <div className="production-order-actions">
          {workspace.capabilities.plan&&["draft","planned"].includes(selected.status)&&<Button disabled={Boolean(busy)} onClick={()=>call(selected.id,"plan_production_order",{target_order:selected.id,start_date:new Date().toISOString().slice(0,10),end_date:null},"تم تخطيط الأمر.")}>تخطيط</Button>}
          {workspace.capabilities.release&&selected.status==="planned"&&<Button disabled={Boolean(busy)} onClick={()=>call(selected.id,"release_production_order",{target_order:selected.id},"تم إصدار الأمر للتنفيذ.")}>إصدار</Button>}
          {workspace.capabilities.complete&&selected.status==="in_progress"&&<Button disabled={Boolean(busy)||!selectedMetrics.materialsComplete||!selectedMetrics.operationsComplete||!selectedMetrics.qualityComplete} onClick={()=>call(selected.id,"complete_production_order",{target_order:selected.id},"تم إكمال أمر الإنتاج.")}>إكمال الأمر</Button>}
          {workspace.capabilities.cancel&&!["completed","cancelled"].includes(selected.status)&&<Button tone="danger" disabled={Boolean(busy)} onClick={()=>cancelOrder(selected)}>إلغاء وعكس</Button>}
        </div>
        {selected.status==="in_progress"&&(!selectedMetrics.materialsComplete||!selectedMetrics.operationsComplete||!selectedMetrics.qualityComplete)&&<Notice type="error">لا يمكن إكمال الأمر الآن: {!selectedMetrics.materialsComplete?"استكمل صرف كل الخامات. ":""}{!selectedMetrics.operationsComplete?"استكمل خطوات التشغيل. ":""}{!selectedMetrics.qualityComplete?"اعتمد مراجعات الجودة المعلقة.":""}</Notice>}

        <section className="production-detail-section">
          <h3>الخامات المطلوبة</h3>
          {selectedMetrics.requirements.map(requirement=>{
            const required=Number(requirement.required_quantity||0),issued=Number(requirement.issued_quantity||0),remaining=Math.max(0,required-issued);
            return <div className="production-material-row" key={requirement.id}>
              <div><strong>{requirement.inventory_item_name}</strong><small>{requirement.warehouse_name}</small></div>
              <div className="production-quantity-triplet"><span>المطلوب <strong>{required}</strong></span><span>المصروف <strong>{issued}</strong></span><span>المتبقي <strong>{remaining}</strong></span></div>
              {workspace.capabilities.issue&&["released","in_progress"].includes(selected.status)&&remaining>0&&<div className="production-inline-action">
                <Field label={`صرف الآن (${requirement.inventory_item_unit||"وحدة"})`}><input type="number" min="0.0001" max={remaining} step="any" style={inputStyle} value={issueQty[requirement.id]??""} placeholder={String(remaining)} onChange={event=>setIssueQty(current=>({...current,[requirement.id]:event.target.value}))}/></Field>
                <Button disabled={busy===requirement.id} onClick={()=>issueMaterial(requirement)}>تسجيل الدفعة</Button>
              </div>}
            </div>;
          })}
          {!selectedMetrics.requirements.length&&<Notice type="error">لا توجد متطلبات خامات. راجع تركيبة المنتج قبل الإصدار.</Notice>}
        </section>

        <section className="production-detail-section">
          <h3>خطوات التشغيل والجودة</h3>
          {selectedMetrics.operations.map(operation=>{
            const assigned=assignments[operation.id]??operation.assigned_employee_id??"";
            const paused=Boolean(operation.paused_at);
            return <article className="production-operation" key={operation.id}>
              <div className="production-operation-heading">
                <div><strong>{operation.sequence_no}. {operation.name}</strong><small>{operation.assigned_employee_name||"لم يُسند لموظف"}</small></div>
                <span><StatusBadge label={STATUS[operation.status]||operation.status}/><StatusBadge label={QUALITY[operation.quality_status]||operation.quality_status}/></span>
              </div>
              {workspace.capabilities.assign&&!["completed","skipped"].includes(operation.status)&&<div className="production-inline-action">
                <Field label="الموظف المسؤول"><select style={inputStyle} value={assigned} onChange={event=>setAssignments({...assignments,[operation.id]:event.target.value})}><option value="">اختر</option>{workspace.employees.map(employee=><option key={employee.id} value={employee.id}>{employee.full_name}{employee.job_title?` · ${employee.job_title}`:""}</option>)}</select></Field>
                <Button tone="ghost" disabled={busy===operation.id||!assigned} onClick={()=>assignOperation(operation)}>حفظ الإسناد</Button>
              </div>}
              <div className="production-operation-actions">
                {workspace.capabilities.operate&&operation.status==="pending"&&<Button disabled={busy===operation.id} onClick={()=>readyOperation(operation)}>تجهيز</Button>}
                {workspace.capabilities.operate&&operation.status==="ready"&&<Button disabled={busy===operation.id||!operation.assigned_employee_id} onClick={()=>operationEvent(operation,"start")}>بدء</Button>}
                {workspace.capabilities.operate&&operation.status==="in_progress"&&!paused&&<><Button tone="ghost" disabled={busy===operation.id} onClick={()=>pauseOperation(operation)}>إيقاف مؤقت</Button><Button disabled={busy===operation.id} onClick={()=>openFinish(operation,selected)}>إنهاء وتسجيل الكميات</Button></>}
                {workspace.capabilities.operate&&operation.status==="in_progress"&&paused&&<Button disabled={busy===operation.id} onClick={()=>operationEvent(operation,"resume")}>استئناف</Button>}
                {workspace.capabilities.assign&&!["completed","skipped"].includes(operation.status)&&<Button tone="danger" disabled={busy===operation.id} onClick={()=>skipOperation(operation)}>تجاوز بسبب</Button>}
                {workspace.capabilities.quality&&operation.status==="completed"&&operation.quality_status==="awaiting_review"&&<><Button disabled={busy===operation.id} onClick={()=>reviewQuality(operation,true)}>اعتماد الجودة</Button><Button tone="danger" disabled={busy===operation.id} onClick={()=>reviewQuality(operation,false)}>رفض الجودة</Button></>}
              </div>
              <details className="production-timeline"><summary>السجل ({eventsFor(operation.id).length})</summary>{eventsFor(operation.id).map(event=><div key={event.id}><strong>{event.event_type}</strong><span>{dateText(event.occurred_at)}{event.reason?` · ${event.reason}`:""}</span></div>)}</details>
            </article>;
          })}
        </section>
      </>}
    </DetailsDrawer>

    <DetailsDrawer open={Boolean(finishing)} title="إنهاء خطوة التشغيل" description="راجع الكميات قبل الإرسال للجودة." onClose={()=>setFinishing(null)} className="production-finish-drawer">
      {finishing&&<div className="production-finish-form">
        <Field label="الكمية المقبولة"><input type="number" min="0" style={inputStyle} value={finishForm.accepted} onChange={event=>setFinishForm({...finishForm,accepted:event.target.value})}/></Field>
        <Field label="الكمية المرفوضة"><input type="number" min="0" style={inputStyle} value={finishForm.rejected} onChange={event=>setFinishForm({...finishForm,rejected:event.target.value})}/></Field>
        <Field label="كمية إعادة التشغيل"><input type="number" min="0" style={inputStyle} value={finishForm.rework} onChange={event=>setFinishForm({...finishForm,rework:event.target.value})}/></Field>
        <Field label="سبب الرفض / إعادة التشغيل"><textarea style={inputStyle} value={finishForm.reason} onChange={event=>setFinishForm({...finishForm,reason:event.target.value})}/></Field>
        <Button disabled={busy===finishing.id} onClick={finishOperation}>إكمال وإرسال للجودة</Button>
      </div>}
    </DetailsDrawer>
  </div>;
}
