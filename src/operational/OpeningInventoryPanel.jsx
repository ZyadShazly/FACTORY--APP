import React,{useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{Button,Field,Notice,Panel,friendlyError,inputStyle,money}from"./ui";

const emptyLine={item:"",warehouse:"",location:"",quantity:"",unitCost:"0",reference:"",reason:""};

export function OpeningInventoryPanel({workspace,onChanged,canViewFinancials=true}){
  const[busy,setBusy]=useState(false);
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[documentId,setDocumentId]=useState("");
  const[header,setHeader]=useState({reference:"",reason:""});
  const[line,setLine]=useState(emptyLine);
  const documents=workspace.opening_documents||[];
  const drafts=documents.filter(d=>d.status==="draft");
  const posted=documents.filter(d=>d.status==="posted");
  const selected=documents.find(d=>d.id===documentId);
  const lines=(workspace.opening_lines||[]).filter(l=>l.document_id===documentId);
  const totals=useMemo(()=>lines.reduce((sum,row)=>({
    quantity:sum.quantity+Number(row.quantity||0),value:sum.value+Number(row.total_value||0)
  }),{quantity:0,value:0}),[lines]);
  const locations=(workspace.locations||[]).filter(l=>!line.warehouse||l.warehouse_id===line.warehouse);

  async function call(name,args,success){
    setBusy(true);setError("");setOk("");
    const{data,error}=await supabase.rpc(name,args);
    if(error)setError(friendlyError(error));else{setOk(success);await onChanged()}
    setBusy(false);return error?null:data;
  }

  async function createDocument(){
    const data=await call("create_opening_inventory_document",{
      document_reference:header.reference.trim()||null,document_reason:header.reason.trim()||null
    },"تم إنشاء مسودة رصيد افتتاحي. أضف البنود ثم راجعها قبل الترحيل.");
    if(data?.id){setDocumentId(data.id);setHeader({reference:"",reason:""})}
  }

  async function addLine(){
    if(!documentId)return setError("أنشئ أو اختر مسودة أولًا.");
    if(!line.item||!line.warehouse)return setError("اختر الصنف والمخزن.");
    if(Number(line.quantity)<=0)return setError("الكمية الافتتاحية يجب أن تكون أكبر من صفر.");
    if(Number(line.unitCost)<0)return setError("تكلفة الوحدة لا يمكن أن تكون سالبة.");
    const saved=await call("save_opening_inventory_line",{
      target_document:documentId,target_line:null,target_inventory_item:line.item,
      target_warehouse:line.warehouse,target_location:line.location||null,
      opening_quantity:Number(line.quantity),opening_unit_cost:Number(line.unitCost),
      line_reference:line.reference.trim()||null,line_reason:line.reason.trim()||null
    },"تم حفظ بند المسودة. لم تتغير الأرصدة بعد.");
    if(saved)setLine(emptyLine);
  }

  async function removeLine(row){
    const reason=window.prompt(`اكتب سبب حذف بند "${row.item_name}" من المسودة.`);
    if(reason===null)return;
    if(!reason.trim())return setError("سبب الحذف مطلوب.");
    await call("delete_opening_inventory_line",{target_line:row.id,deletion_reason:reason.trim()},"تم حذف بند المسودة مع تسجيل السبب.");
  }

  async function postDocument(){
    if(!selected||selected.status!=="draft")return setError("اختر مسودة صالحة للترحيل.");
    if(!lines.length)return setError("أضف بندًا واحدًا على الأقل.");
    if(!window.confirm(`سيتم ترحيل ${money(totals.quantity)} وحدة بقيمة ${money(totals.value)} إلى دفتر المخزون. بعد الترحيل لن يمكن تعديل المستند أو حذفه. متابعة؟`))return;
    const result=await call("post_opening_inventory_document",{target_document:documentId},"تم اعتماد الرصيد الافتتاحي وترحيله إلى دفتر المخزون.");
    if(result)setDocumentId("");
  }

  return <Panel title="الرصيد الافتتاحي">
    <p style={{color:"var(--color-text-muted)"}}>المسودة لا تؤثر على الرصيد. راجع البنود ثم اعتمد المستند لإنشاء حركات <code>opening_balance</code> غير قابلة للتعديل. أي تصحيح لاحق يتم بتسوية موثقة من قسم التسويات.</p>
    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
    <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(190px,1fr))",gap:10,alignItems:"end",marginBottom:14}}>
      <Field label="مرجع المستند"><input style={inputStyle} value={header.reference} onChange={e=>setHeader({...header,reference:e.target.value})}/></Field>
      <Field label="سبب / ملاحظة"><input style={inputStyle} value={header.reason} onChange={e=>setHeader({...header,reason:e.target.value})}/></Field>
      <Button disabled={busy} onClick={createDocument}>مستند جديد</Button>
      <Field label="المسودات"><select style={inputStyle} value={documentId} onChange={e=>setDocumentId(e.target.value)}><option value="">اختر مسودة</option>{drafts.map(d=><option key={d.id} value={d.id}>{d.document_number} — {d.reference||"بدون مرجع"}</option>)}</select></Field>
    </div>

    {selected?.status==="draft"&&<>
      <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(160px,1fr))",gap:10,alignItems:"end",padding:12,border:"1px solid var(--color-border)",borderRadius:10}}>
        <Field label="صنف المخزون"><select style={inputStyle} value={line.item} onChange={e=>setLine({...line,item:e.target.value})}><option value="">اختر</option>{(workspace.items||[]).map(i=><option key={i.id} value={i.id}>{i.sku} — {i.name}</option>)}</select></Field>
        <Field label="المخزن"><select style={inputStyle} value={line.warehouse} onChange={e=>setLine({...line,warehouse:e.target.value,location:""})}><option value="">اختر</option>{(workspace.warehouses||[]).map(w=><option key={w.id} value={w.id}>{w.name}</option>)}</select></Field>
        <Field label="الموقع (اختياري)"><select style={inputStyle} value={line.location} onChange={e=>setLine({...line,location:e.target.value})}><option value="">بدون موقع</option>{locations.map(l=><option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
        <Field label="الكمية الافتتاحية"><input style={inputStyle} type="number" min="0" step="any" value={line.quantity} onChange={e=>setLine({...line,quantity:e.target.value})}/></Field>
        <Field label="تكلفة الوحدة"><input style={inputStyle} type="number" min="0" step="any" value={line.unitCost} onChange={e=>setLine({...line,unitCost:e.target.value})}/></Field>
        <Field label="مرجع البند"><input style={inputStyle} value={line.reference} onChange={e=>setLine({...line,reference:e.target.value})}/></Field>
        <Field label="السبب"><input style={inputStyle} value={line.reason} onChange={e=>setLine({...line,reason:e.target.value})}/></Field>
        <Button disabled={busy} onClick={addLine}>إضافة بند</Button>
      </div>
      <div style={{overflowX:"auto",marginTop:14}}><table style={{width:"100%",borderCollapse:"collapse"}}><thead><tr>{["الصنف","المخزن","الموقع","الكمية","تكلفة الوحدة","القيمة","المرجع",""].map(h=><th key={h} style={{textAlign:"right",padding:8,borderBottom:"1px solid var(--color-border)"}}>{h}</th>)}</tr></thead><tbody>
        {lines.map(row=><tr key={row.id}><td style={{padding:8}}>{row.item_name}</td><td>{row.warehouse_name}</td><td>{row.location_name||"—"}</td><td>{money(row.quantity)}</td><td>{canViewFinancials?money(row.unit_cost):"—"}</td><td>{canViewFinancials?money(row.total_value):"—"}</td><td>{row.reference||"—"}</td><td><Button tone="danger" disabled={busy} onClick={()=>removeLine(row)}>حذف</Button></td></tr>)}
        {!lines.length&&<tr><td colSpan="8" style={{padding:12,textAlign:"center"}}>لم تضف بنودًا بعد.</td></tr>}
      </tbody></table></div>
      <Notice>المراجعة: إجمالي الكمية {money(totals.quantity)}{canViewFinancials&&<> — إجمالي القيمة {money(totals.value)}</>}</Notice>
      <Button disabled={busy||!lines.length} onClick={postDocument}>مراجعة واعتماد / ترحيل</Button>
    </>}

    <details className="inventory-collapsible">
      <summary>السجل المرحّل ({posted.length})</summary>
      <div style={{display:"grid",gap:8,marginTop:8}}>{posted.map(d=>{
        const documentLines=(workspace.opening_lines||[]).filter(l=>l.document_id===d.id);
        const quantity=documentLines.reduce((sum,row)=>sum+Number(row.quantity||0),0);
        const value=documentLines.reduce((sum,row)=>sum+Number(row.total_value||0),0);
        return <div key={d.id} style={{display:"flex",justifyContent:"space-between",gap:12,padding:10,border:"1px solid var(--color-border)",borderRadius:9}}>
          <span><strong>{d.document_number}</strong><small style={{display:"block",color:"var(--color-text-muted)"}}>{d.reference||"بدون مرجع"} — مرحّل وغير قابل للتعديل</small></span>
          <span>{money(quantity)}{canViewFinancials&&<> — {money(value)}</>}</span>
        </div>
      })}{!posted.length&&<span>لا توجد مستندات أرصدة افتتاحية مرحّلة.</span>}</div>
    </details>
  </Panel>;
}
