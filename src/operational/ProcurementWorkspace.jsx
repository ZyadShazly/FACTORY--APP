import React,{useEffect,useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{formatMoney,getCurrencySettings}from"../userExperience";
import{
  ArchiveSection,Button,DetailsDrawer,Field,FoundationEmptyState,HelpText,KpiCard,KpiGrid,
  Notice,PageHeader,Panel,PrimaryActionBar,ResponsiveTable,SearchFilterBar,StatusBadge,
  friendlyError,inputStyle
}from"./ui";

const LABEL={
  draft:"مسودة",submitted:"بانتظار الاعتماد",approved:"معتمد",rejected:"مرفوض",
  cancelled:"ملغي",converted:"تم التحويل",completed:"مكتمل",received:"عرض مستلم",
  selected:"مختار",partially_received:"استلام جزئي",fully_received:"مستلم بالكامل",
  invoiced:"مفوتر",closed:"مغلق",sent:"مرسل للمورد",confirmed:"مؤكد",matched:"مطابق"
};
const TONE={approved:"success",completed:"success",confirmed:"success",matched:"success",sent:"info",converted:"info",received:"info",selected:"info",submitted:"warning",draft:"neutral",partially_received:"warning",fully_received:"success",invoiced:"success",rejected:"danger",cancelled:"danger",closed:"neutral"};
const TABS=[
  ["requests","طلبات الشراء"],["quotes","عروض الموردين"],["orders","أوامر الشراء"],
  ["receipts","الاستلام"],["invoices","فواتير الموردين"]
];
const REQUEST_ACTIVE=new Set(["draft","submitted","approved"]);
const ORDER_ACTIVE=new Set(["draft","approved","sent","partially_received","fully_received"]);
const emptyWorkspace={requests:[],request_items:[],request_history:[],quotes:[],quote_items:[],orders:[],order_items:[],order_audit:[],receipts:[],receipt_items:[],invoices:[],invoice_lines:[],capabilities:{}};
const cardStyle={border:"1px solid var(--color-border)",borderRadius:12,padding:12,display:"flex",justifyContent:"space-between",gap:12,flexWrap:"wrap",alignItems:"center",background:"var(--color-surface)"};
const actionsStyle={display:"flex",gap:8,flexWrap:"wrap",alignItems:"center"};
const formStyle={display:"flex",gap:10,flexWrap:"wrap",alignItems:"end"};

function Status({value}){return <StatusBadge label={LABEL[value]||value||"—"} tone={TONE[value]||"neutral"}/>}
function Empty({title="لا توجد سجلات نشطة",description="ستظهر السجلات هنا عند بدء هذه الخطوة."}){return <FoundationEmptyState title={title} description={description}/>}
function recordName(row,serialKey){return row?.display_name||row?.[serialKey]||"مستند مشتريات"}
function DocumentIdentity({row,serialKey}){return <span><strong>{recordName(row,serialKey)}</strong><br/><small>المرجع الداخلي: {row?.[serialKey]||"—"}</small></span>}

function ProcurementDocument({
  selection,workspace,projects,suppliers,onApproveRequest,onRejectRequest,onApproveOrder,
  onSendOrder,onRenameOrder,sendReference,setSendReference,orderName,setOrderName
}){
  if(!selection)return null;
  const{type,row}=selection;
  const order=type==="order"?row:workspace.orders.find(item=>item.id===(row.purchase_order_id||row.id));
  const projectId=row.project_id||order?.project_id;
  const supplierId=row.supplier_id||order?.supplier_id;
  const project=projects.find(item=>item.id===projectId);
  const supplier=suppliers.find(item=>item.id===supplierId);
  const config={
    request:{title:"طلب شراء",numberKey:"request_number",date:row.created_at},
    order:{title:"أمر شراء",numberKey:"order_number",date:row.order_date||row.created_at},
    receipt:{title:"إذن استلام",numberKey:"receipt_number",date:row.received_at||row.created_at},
    invoice:{title:"فاتورة مورد",numberKey:"invoice_number",date:row.invoice_date||row.created_at}
  }[type];
  let lines=[];
  if(type==="request")lines=workspace.request_items.filter(item=>item.purchase_request_id===row.id).map(item=>({...item,unit_price:item.estimated_unit_cost,tax_amount:0,line_total:item.estimated_total}));
  if(type==="order")lines=workspace.order_items.filter(item=>item.purchase_order_id===row.id);
  if(type==="receipt")lines=workspace.receipt_items.filter(item=>item.goods_receipt_id===row.id).map(item=>{const source=workspace.order_items.find(orderItem=>orderItem.id===item.purchase_order_item_id)||{};return{...source,...item,description:source.description||"بند مستلم",quantity:item.accepted_quantity,unit_price:source.unit_price||0,tax_amount:source.tax_amount||0,line_total:Number(item.accepted_quantity||0)*Number(source.unit_price||0)}});
  if(type==="invoice")lines=workspace.invoice_lines.filter(item=>item.supplier_invoice_id===row.id);
  const subtotal=lines.reduce((sum,item)=>sum+(Number(item.quantity||0)*Number(item.unit_price||0)),0);
  const discount=lines.reduce((sum,item)=>sum+Number(item.discount_amount||0),0);
  const vat=lines.reduce((sum,item)=>sum+Number(item.tax_amount||0),0);
  const total=lines.reduce((sum,item)=>sum+Number(item.line_total??(Number(item.quantity||0)*Number(item.unit_price||0)-Number(item.discount_amount||0)+Number(item.tax_amount||0))),0);
  const timeline=type==="request"
    ?workspace.request_history.filter(item=>item.purchase_request_id===row.id)
    :type==="order"
      ?workspace.order_audit.filter(item=>item.record_id===row.id)
      :[];
  return <article className="procurement-print-document" dir="rtl" data-document-type={type}>
    <header className="procurement-document-header">
      <img src="/logo.png" alt="NEXTEP"/>
      <div><span>NextEP Factory ERP</span><h2>{config.title}</h2><strong>{recordName(row,config.numberKey)}</strong><small>{row[config.numberKey]}</small></div>
      <Status value={row.status}/>
    </header>
    <section className="procurement-document-meta">
      <div><small>المشروع</small><strong>{project?.project_name||project?.name||"بدون مشروع"}</strong></div>
      <div><small>المورد</small><strong>{supplier?.name||"غير مطلوب لهذا المستند"}</strong></div>
      <div><small>التاريخ</small><strong>{String(config.date||"").slice(0,10)||"—"}</strong></div>
      <div><small>رقم المستند</small><strong>{row[config.numberKey]||"—"}</strong></div>
    </section>
    <ResponsiveTable headers={["الوصف","الكمية","سعر الوحدة","الخصم","الضريبة","الإجمالي"]}>
      {lines.map(item=><tr key={item.id}><td>{item.description}</td><td>{Number(item.quantity||0).toLocaleString("ar-EG")}</td><td>{formatMoney(item.unit_price)}</td><td>{formatMoney(item.discount_amount)}</td><td>{formatMoney(item.tax_amount)}</td><td>{formatMoney(item.line_total)}</td></tr>)}
    </ResponsiveTable>
    <section className="procurement-document-totals">
      <div><span>الإجمالي قبل الخصم والضريبة</span><strong>{formatMoney(row.subtotal??subtotal)}</strong></div>
      <div><span>الخصم</span><strong>{formatMoney(row.discount_amount??discount)}</strong></div>
      <div><span>ضريبة القيمة المضافة</span><strong>{formatMoney(row.tax_amount??vat)}</strong></div>
      <div className="is-total"><span>الإجمالي النهائي</span><strong>{formatMoney(row.total_amount??total)}</strong></div>
    </section>
    {type==="order"&&row.status==="draft"&&<HelpText title="لماذا الأمر مسودة؟">راجع البنود والأسعار والضريبة أولًا. الاعتماد متاح من هذه المعاينة فقط حتى لا يرسل أمر غير مراجع.</HelpText>}
    {timeline.length>0&&<section className="procurement-document-timeline" aria-label="سجل الحالة"><h3>سجل الحالة والتدقيق</h3>{timeline.map(entry=><div key={entry.id}><Status value={entry.to_status||(entry.new_data?.status)||row.status}/><span>{entry.action?LABEL[entry.action]||entry.action:"تغيير الحالة"}</span><small>{new Date(entry.changed_at||entry.created_at).toLocaleString("ar-EG")}</small>{entry.reason&&<p>السبب: {entry.reason}</p>}</div>)}</section>}
    <section className="procurement-document-signatures">
      <div><span>إعداد</span><b>الاسم / التوقيع</b></div><div><span>مراجعة</span><b>الاسم / التوقيع</b></div><div><span>اعتماد</span><b>الاسم / التوقيع</b></div>
    </section>
    <div className="procurement-preview-actions" data-print-hidden>
      <Button onClick={()=>window.print()}>طباعة / حفظ PDF</Button>
      {type==="request"&&row.status==="submitted"&&<><Button tone="danger" onClick={()=>onRejectRequest(row)}>رفض بسبب</Button><Button onClick={()=>onApproveRequest(row)}>اعتماد الطلب</Button></>}
      {type==="order"&&row.status==="draft"&&<><Field label="اسم أمر الشراء"><input style={inputStyle} value={orderName} onChange={event=>setOrderName(event.target.value)}/></Field><Button tone="ghost" onClick={()=>onRenameOrder(row)}>حفظ الاسم</Button><Button onClick={()=>onApproveOrder(row)}>اعتماد بعد المعاينة</Button></>}
      {type==="order"&&row.status==="approved"&&<><Field label="مرجع الإرسال للمورد"><input style={inputStyle} value={sendReference} onChange={event=>setSendReference(event.target.value)} placeholder="بريد / واتساب / مرجع خارجي"/></Field><Button onClick={()=>onSendOrder(row)}>إرسال بعد المعاينة</Button></>}
    </div>
  </article>;
}

export function ProcurementWorkspace({data}){
  const[ws,setWs]=useState(emptyWorkspace),[inventory,setInventory]=useState({warehouses:[]});
  const[error,setError]=useState(""),[ok,setOk]=useState(""),[loading,setLoading]=useState(true);
  const[tab,setTab]=useState("requests"),[search,setSearch]=useState(""),[creating,setCreating]=useState(false);
  const[selected,setSelected]=useState(null),[rejecting,setRejecting]=useState(null),[rejectReason,setRejectReason]=useState("");
  const[request,setRequest]=useState({display_name:"",project_id:"",material_id:"",description:"",quantity:"",unit:"قطعة",estimated_unit_cost:"",justification:""});
  const currencyCode=getCurrencySettings().currency_code;
  const[quote,setQuote]=useState({request_id:"",supplier_id:"",unit_price:"",currency:currencyCode});
  const[draftOrder,setDraftOrder]=useState({quote_id:"",display_name:""});
  const[receipt,setReceipt]=useState({order_id:"",warehouse_id:"",delivery_ref:""});
  const[invoice,setInvoice]=useState({order_id:"",invoice_number:"",invoice_date:new Date().toISOString().slice(0,10)});
  const[sendReference,setSendReference]=useState(""),[orderName,setOrderName]=useState("");

  const projects=data.projects||[],suppliers=data.suppliers||[],materials=data.materials||[];
  async function load(){
    setLoading(true);setError("");
    const[p,i]=await Promise.all([supabase.rpc("get_procurement_workspace_v2",{target_project:null}),supabase.rpc("get_inventory_workspace")]);
    if(p.error)setError(friendlyError(p.error));else setWs({...emptyWorkspace,...(p.data||{})});
    if(i.error)setError(current=>current||friendlyError(i.error));else setInventory(i.data||{warehouses:[]});
    setLoading(false);
  }
  useEffect(()=>{void load()},[]);
  async function call(name,args,msg,{keepSelection=false}={}){
    setError("");setOk("");
    const{data:result,error:callError}=await supabase.rpc(name,args);
    if(callError){setError(friendlyError(callError));return false}
    setOk(msg);if(!keepSelection)setSelected(null);setRejecting(null);setRejectReason("");await load();return result||true;
  }
  async function saveRequest(){
    if(!request.display_name.trim())return setError("أدخل اسمًا واضحًا لطلب الشراء.");
    if(!request.description.trim()||Number(request.quantity)<=0)return setError("أدخل وصفًا وكمية صحيحة.");
    const saved=await call("save_purchase_request_v2",{payload:{display_name:request.display_name,project_id:request.project_id||null,required_date:null,priority:"normal",justification:request.justification,items:[{material_id:request.material_id||null,description:request.description,quantity:Number(request.quantity),unit:request.unit,estimated_unit_cost:Number(request.estimated_unit_cost||0),sequence:1}]}},"تم حفظ طلب الشراء كمسودة.");
    if(saved){setCreating(false);setRequest({...request,display_name:"",description:"",quantity:"",estimated_unit_cost:"",justification:""})}
  }
  async function saveQuote(){
    const items=ws.request_items.filter(item=>item.purchase_request_id===quote.request_id);
    if(!quote.request_id||!quote.supplier_id||!items.length)return setError("اختر طلبًا معتمدًا وموردًا.");
    await call("save_supplier_quote",{payload:{purchase_request_id:quote.request_id,supplier_id:quote.supplier_id,supplier_reference:null,quote_date:new Date().toISOString().slice(0,10),currency:quote.currency,payment_terms:null,delivery_days:null,items:items.map(item=>({purchase_request_item_id:item.id,quantity:Number(item.quantity),unit_price:Number(quote.unit_price||0),discount_amount:0,tax_amount:0}))}},"تم تسجيل عرض المورد.");
  }
  async function createDraftOrder(){
    if(!draftOrder.quote_id||!draftOrder.display_name.trim())return setError("اختر عرض المورد واكتب اسمًا واضحًا لأمر الشراء.");
    const saved=await call("create_purchase_order_draft_from_quote",{target_quote:draftOrder.quote_id,order_display_name:draftOrder.display_name.trim()},"تم إنشاء أمر الشراء كمسودة للمراجعة.");
    if(saved){setDraftOrder({quote_id:"",display_name:""});setTab("orders")}
  }
  async function receiveOrder(){
    if(!receipt.order_id||!receipt.warehouse_id)return setError("اختر أمر الشراء والمخزن المستلم.");
    const items=ws.order_items.filter(item=>item.purchase_order_id===receipt.order_id&&Number(item.received_quantity)<Number(item.quantity));
    if(!items.length)return setError("لا توجد كميات متبقية للاستلام.");
    await call("confirm_goods_receipt_to_inventory",{payload:{purchase_order_id:receipt.order_id,supplier_delivery_reference:receipt.delivery_ref,notes:null,items:items.map(item=>({purchase_order_item_id:item.id,quantity_received:Number(item.quantity)-Number(item.received_quantity),accepted_quantity:Number(item.quantity)-Number(item.received_quantity),condition:"accepted"}))},target_warehouse:receipt.warehouse_id,target_location:null},"تم تأكيد الاستلام وترحيل الكميات للمخزون.");
  }
  async function approveInvoice(){
    const order=ws.orders.find(item=>item.id===invoice.order_id),items=ws.order_items.filter(item=>item.purchase_order_id===invoice.order_id);
    if(!order||!invoice.invoice_number.trim()||!items.length)return setError("اختر أمر شراء مستلمًا وأدخل رقم الفاتورة.");
    await call("approve_supplier_invoice",{payload:{invoice_number:invoice.invoice_number,purchase_order_id:invoice.order_id,invoice_date:invoice.invoice_date,due_date:null,notes:null,items:items.map(item=>({purchase_order_item_id:item.id,goods_receipt_item_id:null,description:item.description,quantity:Number(item.quantity),unit_price:Number(item.unit_price),discount_amount:Number(item.discount_amount||0),tax_amount:Number(item.tax_amount||0),budget_item_id:item.budget_item_id||null,milestone_id:item.milestone_id||null}))}},"تم اعتماد فاتورة المورد وتسجيل التكلفة الفعلية مرة واحدة.");
  }
  function projectName(id){const project=projects.find(item=>item.id===id);return project?.project_name||project?.name||"بدون مشروع"}
  function supplierName(id){return suppliers.find(item=>item.id===id)?.name||"—"}
  function openDocument(type,row){setSelected({type,row});setSendReference(row.supplier_send_reference||"");setOrderName(row.display_name||"")}
  function matches(row,serialKey){const value=`${row.display_name||""} ${row[serialKey]||""} ${LABEL[row.status]||row.status||""}`.toLowerCase();return value.includes(search.trim().toLowerCase())}
  const activeRequests=useMemo(()=>ws.requests.filter(row=>REQUEST_ACTIVE.has(row.status)&&matches(row,"request_number")),[ws.requests,search]);
  const previousRequests=useMemo(()=>ws.requests.filter(row=>!REQUEST_ACTIVE.has(row.status)&&matches(row,"request_number")),[ws.requests,search]);
  const activeOrders=useMemo(()=>ws.orders.filter(row=>ORDER_ACTIVE.has(row.status)&&matches(row,"order_number")),[ws.orders,search]);
  const previousOrders=useMemo(()=>ws.orders.filter(row=>!ORDER_ACTIVE.has(row.status)&&matches(row,"order_number")),[ws.orders,search]);
  const approvedRequests=ws.requests.filter(row=>row.status==="approved");
  const receivedQuotes=ws.quotes.filter(row=>row.status==="received");
  const receivableOrders=ws.orders.filter(row=>["approved","sent","partially_received"].includes(row.status));
  const invoiceableOrders=ws.orders.filter(row=>["partially_received","fully_received"].includes(row.status));

  const requestCard=row=><div key={row.id} style={cardStyle}><DocumentIdentity row={row} serialKey="request_number"/><span>{projectName(row.project_id)}</span><Status value={row.status}/><span style={actionsStyle}><Button tone="ghost" onClick={()=>openDocument("request",row)}>معاينة التفاصيل</Button>{row.status==="draft"&&<Button onClick={()=>call("submit_purchase_request",{target_id:row.id},"تم إرسال الطلب للاعتماد.")}>إرسال للاعتماد</Button>}</span></div>;
  const orderCard=row=><div key={row.id} style={cardStyle}><DocumentIdentity row={row} serialKey="order_number"/><span>{supplierName(row.supplier_id)} · {formatMoney(row.total_amount)}</span><Status value={row.status}/><Button onClick={()=>openDocument("order",row)}>معاينة المستند</Button></div>;

  return <div className="procurement-workspace">
    <PageHeader eyebrow="المشتريات والتوريد" title="دورة المشتريات" description="كل مستند له خطوة واضحة: اطلب، راجع، اعتمد، أرسل، استلم، ثم سجّل الفاتورة."/>
    <KpiGrid>
      <KpiCard label="طلبات تنتظر الاعتماد" value={ws.requests.filter(row=>row.status==="submitted").length} tone="warning"/>
      <KpiCard label="أوامر شراء مسودة" value={ws.orders.filter(row=>row.status==="draft").length}/>
      <KpiCard label="أوامر قيد الاستلام" value={receivableOrders.length} tone="info"/>
      <KpiCard label="فواتير معتمدة" value={ws.invoices.filter(row=>row.status==="approved").length} tone="success"/>
    </KpiGrid>
    <PrimaryActionBar primaryAction={<Button onClick={()=>{setTab("requests");setCreating(true)}}>+ طلب شراء جديد</Button>}>
      <nav className="procurement-tabs" aria-label="مراحل دورة المشتريات">{TABS.map(([id,label])=><button type="button" key={id} className={tab===id?"is-active":""} onClick={()=>setTab(id)}>{label}</button>)}</nav>
    </PrimaryActionBar>
    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
    {loading?<Notice>جاري تحميل دورة المشتريات...</Notice>:<>
      <SearchFilterBar value={search} onChange={event=>setSearch(event.target.value)} placeholder="ابحث بالاسم أو الرقم الداخلي أو الحالة"/>
      {tab==="requests"&&<>
        {creating&&<Panel title="طلب شراء جديد" actions={<Button tone="ghost" onClick={()=>setCreating(false)}>إغلاق</Button>}><div style={formStyle}>
          <Field label="اسم الطلب"><input required style={inputStyle} value={request.display_name} onChange={event=>setRequest({...request,display_name:event.target.value})} placeholder="مثال: أخشاب مشروع المعرض"/></Field>
          <Field label="المشروع"><select style={inputStyle} value={request.project_id} onChange={event=>setRequest({...request,project_id:event.target.value})}><option value="">بدون مشروع</option>{projects.map(project=><option key={project.id} value={project.id}>{project.project_name||project.name}</option>)}</select></Field>
          <Field label="المادة"><select style={inputStyle} value={request.material_id} onChange={event=>setRequest({...request,material_id:event.target.value})}><option value="">اختر</option>{materials.map(material=><option key={material.id} value={material.id}>{material.name}</option>)}</select></Field>
          <Field label="الوصف"><input style={inputStyle} value={request.description} onChange={event=>setRequest({...request,description:event.target.value})}/></Field>
          <Field label="الكمية"><input type="number" min="0" style={inputStyle} value={request.quantity} onChange={event=>setRequest({...request,quantity:event.target.value})}/></Field>
          <Field label="تكلفة الوحدة التقديرية"><input type="number" min="0" style={inputStyle} value={request.estimated_unit_cost} onChange={event=>setRequest({...request,estimated_unit_cost:event.target.value})}/></Field>
          <Button onClick={saveRequest}>حفظ المسودة</Button>
        </div></Panel>}
        <Panel title={`الطلبات النشطة (${activeRequests.length})`}><div className="procurement-record-list">{activeRequests.map(requestCard)}{!activeRequests.length&&<Empty title="لا توجد طلبات شراء نشطة"/>}</div></Panel>
        <ArchiveSection title="طلبات الشراء السابقة" count={previousRequests.length} helpText="الطلبات المحولة والمكتملة والمرفوضة محفوظة هنا ولا تُحذف عند التحويل."><div className="procurement-record-list">{previousRequests.map(requestCard)}{!previousRequests.length&&<Empty title="لا يوجد سجل سابق"/>}</div></ArchiveSection>
      </>}
      {tab==="quotes"&&<>
        {ws.capabilities.quote&&<Panel title="تسجيل عرض مورد"><div style={formStyle}>
          <Field label="الطلب المعتمد"><select style={inputStyle} value={quote.request_id} onChange={event=>setQuote({...quote,request_id:event.target.value})}><option value="">اختر</option>{approvedRequests.map(row=><option key={row.id} value={row.id}>{recordName(row,"request_number")} · {row.request_number}</option>)}</select></Field>
          <Field label="المورد"><select style={inputStyle} value={quote.supplier_id} onChange={event=>setQuote({...quote,supplier_id:event.target.value})}><option value="">اختر</option>{suppliers.map(row=><option key={row.id} value={row.id}>{row.name}</option>)}</select></Field>
          <Field label="سعر الوحدة"><input type="number" min="0" style={inputStyle} value={quote.unit_price} onChange={event=>setQuote({...quote,unit_price:event.target.value})}/></Field>
          <Field label="العملة"><input readOnly style={inputStyle} value={quote.currency}/></Field><Button onClick={saveQuote}>حفظ العرض</Button>
        </div></Panel>}
        {ws.capabilities.order&&<Panel title="إنشاء أمر شراء مسودة"><HelpText title="الخطوة التالية">اختيار العرض ينشئ مسودة فقط. يجب فتح المعاينة ومراجعة الأسعار والضريبة قبل الاعتماد.</HelpText><div style={formStyle}>
          <Field label="عرض المورد"><select style={inputStyle} value={draftOrder.quote_id} onChange={event=>{const quoteRow=ws.quotes.find(row=>row.id===event.target.value);const requestRow=ws.requests.find(row=>row.id===quoteRow?.purchase_request_id);setDraftOrder({quote_id:event.target.value,display_name:requestRow?.display_name||""})}}><option value="">اختر</option>{receivedQuotes.map(row=><option key={row.id} value={row.id}>{row.quote_number} · {supplierName(row.supplier_id)}</option>)}</select></Field>
          <Field label="اسم أمر الشراء"><input style={inputStyle} value={draftOrder.display_name} onChange={event=>setDraftOrder({...draftOrder,display_name:event.target.value})} placeholder="اسم واضح للمستخدم"/></Field>
          <Button onClick={createDraftOrder}>إنشاء المسودة</Button>
        </div></Panel>}
        <Panel title="عروض الموردين"><div className="procurement-record-list">{ws.quotes.map(row=><div key={row.id} style={cardStyle}><DocumentIdentity row={row} serialKey="quote_number"/><span>{supplierName(row.supplier_id)}</span><Status value={row.status}/></div>)}{!ws.quotes.length&&<Empty title="لا توجد عروض موردين"/>}</div></Panel>
      </>}
      {tab==="orders"&&<>
        <Panel title={`أوامر الشراء النشطة (${activeOrders.length})`}><div className="procurement-record-list">{activeOrders.map(orderCard)}{!activeOrders.length&&<Empty title="لا توجد أوامر شراء نشطة"/>}</div></Panel>
        <ArchiveSection title="أوامر الشراء السابقة" count={previousOrders.length}><div className="procurement-record-list">{previousOrders.map(orderCard)}{!previousOrders.length&&<Empty title="لا يوجد سجل أوامر سابق"/>}</div></ArchiveSection>
      </>}
      {tab==="receipts"&&<>
        {ws.capabilities.receive&&<Panel title="استلام أمر شراء وترحيله للمخزون"><div style={formStyle}>
          <Field label="أمر الشراء"><select style={inputStyle} value={receipt.order_id} onChange={event=>setReceipt({...receipt,order_id:event.target.value})}><option value="">اختر</option>{receivableOrders.map(row=><option key={row.id} value={row.id}>{recordName(row,"order_number")} · {row.order_number}</option>)}</select></Field>
          <Field label="المخزن"><select style={inputStyle} value={receipt.warehouse_id} onChange={event=>setReceipt({...receipt,warehouse_id:event.target.value})}><option value="">اختر</option>{inventory.warehouses.map(row=><option key={row.id} value={row.id}>{row.name}</option>)}</select></Field>
          <Field label="مرجع التسليم"><input style={inputStyle} value={receipt.delivery_ref} onChange={event=>setReceipt({...receipt,delivery_ref:event.target.value})}/></Field>
          <Button onClick={receiveOrder}>استلام وترحيل</Button>
        </div></Panel>}
        <Panel title="إيصالات الاستلام"><div className="procurement-record-list">{ws.receipts.map(row=><div key={row.id} style={cardStyle}><DocumentIdentity row={row} serialKey="receipt_number"/><Status value={row.status}/><Button onClick={()=>openDocument("receipt",row)}>معاينة وطباعة</Button></div>)}{!ws.receipts.length&&<Empty title="لا توجد إيصالات استلام"/>}</div></Panel>
      </>}
      {tab==="invoices"&&<>
        {ws.capabilities.invoice&&<Panel title="مراجعة واعتماد فاتورة المورد"><div style={formStyle}>
          <Field label="أمر الشراء المستلم"><select style={inputStyle} value={invoice.order_id} onChange={event=>setInvoice({...invoice,order_id:event.target.value})}><option value="">اختر</option>{invoiceableOrders.map(row=><option key={row.id} value={row.id}>{recordName(row,"order_number")} · {row.order_number}</option>)}</select></Field>
          <Field label="رقم الفاتورة"><input style={inputStyle} value={invoice.invoice_number} onChange={event=>setInvoice({...invoice,invoice_number:event.target.value})}/></Field>
          <Field label="تاريخ الفاتورة"><input type="date" style={inputStyle} value={invoice.invoice_date} onChange={event=>setInvoice({...invoice,invoice_date:event.target.value})}/></Field>
          <Button onClick={approveInvoice}>اعتماد الفاتورة</Button>
        </div></Panel>}
        <Panel title="فواتير الموردين"><div className="procurement-record-list">{ws.invoices.map(row=><div key={row.id} style={cardStyle}><DocumentIdentity row={row} serialKey="invoice_number"/><span>{supplierName(row.supplier_id)} · {formatMoney(row.total_amount)}</span><Status value={row.status}/><Button onClick={()=>openDocument("invoice",row)}>معاينة وطباعة</Button></div>)}{!ws.invoices.length&&<Empty title="لا توجد فواتير موردين"/>}</div></Panel>
      </>}
    </>}
    <DetailsDrawer open={Boolean(selected)} title={selected?`${{request:"معاينة طلب الشراء",order:"معاينة أمر الشراء",receipt:"معاينة إذن الاستلام",invoice:"معاينة فاتورة المورد"}[selected.type]}`:""} description="المعاينة هي نفس محتوى الطباعة." onClose={()=>setSelected(null)} className="procurement-preview-drawer">
      <ProcurementDocument
        selection={selected} workspace={ws} projects={projects} suppliers={suppliers}
        sendReference={sendReference} setSendReference={setSendReference}
        orderName={orderName} setOrderName={setOrderName}
        onApproveRequest={row=>call("decide_purchase_request",{target_id:row.id,approve:true,reason:null},"تم اعتماد الطلب بعد مراجعة التفاصيل.")}
        onRejectRequest={row=>setRejecting(row)}
        onApproveOrder={row=>call("approve_purchase_order",{target_order:row.id},"تم اعتماد أمر الشراء بعد المعاينة.")}
        onSendOrder={row=>call("mark_purchase_order_sent",{target_order:row.id,send_reference:sendReference||null},"تم تسجيل إرسال أمر الشراء للمورد.")}
        onRenameOrder={async row=>{if(!orderName.trim())return setError("اسم أمر الشراء مطلوب.");const saved=await call("set_purchase_order_display_name",{target_id:row.id,new_display_name:orderName.trim()},"تم تحديث اسم أمر الشراء.",{keepSelection:true});if(saved!==true)setSelected({type:"order",row:saved})}}
      />
    </DetailsDrawer>
    {rejecting&&<div className="procurement-rejection-layer" role="dialog" aria-modal="true" aria-label="رفض طلب الشراء"><div><h3>رفض طلب الشراء</h3><Field label="سبب الرفض"><textarea style={{...inputStyle,width:"100%",minHeight:110}} value={rejectReason} onChange={event=>setRejectReason(event.target.value)} placeholder="اكتب سببًا واضحًا ليعرف مقدم الطلب المطلوب تعديله"/></Field><span style={actionsStyle}><Button tone="ghost" onClick={()=>{setRejecting(null);setRejectReason("")}}>رجوع</Button><Button tone="danger" onClick={()=>{if(!rejectReason.trim())return setError("سبب الرفض مطلوب.");void call("decide_purchase_request",{target_id:rejecting.id,approve:false,reason:rejectReason.trim()},"تم رفض الطلب مع تسجيل السبب.")}}>تأكيد الرفض</Button></span></div></div>}
  </div>;
}
