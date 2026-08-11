import React,{useCallback,useEffect,useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{ConfirmDialog}from"../v22/shared";
import{Button,Field,Notice,Panel,friendlyError,inputStyle,money}from"./ui";

const EMPTY={due:0,sources:[],targets:[],allocations:[],transactions:[]};
const CLASS_LABEL={settlement:"تسوية",advance:"سلفة",mixed:"تسوية + سلفة"};
const STATUS_LABEL={posted:"مرحّل",reversed:"معكوس",allocated:"مخصص"};

function nextCommandId(){return globalThis.crypto.randomUUID()}

export function CommercialAdvancesPanel({partyType,partyId,canReverse=false,onChanged}){
  const[workspace,setWorkspace]=useState(EMPTY);
  const[loading,setLoading]=useState(true);
  const[busy,setBusy]=useState(false);
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[form,setForm]=useState({sourceId:"",targetKey:"",amount:"",commandId:""});
  const[action,setAction]=useState(null);
  const[reason,setReason]=useState("");

  const load=useCallback(async()=>{
    if(!partyId)return;
    setLoading(true);
    const{data,error}=await supabase.rpc("get_commercial_advance_workspace",{party_type:partyType,target_party:partyId});
    if(error)setError(friendlyError(error));else{setWorkspace({...EMPTY,...(data||{})});setError("")}
    setLoading(false);
  },[partyId,partyType]);
  useEffect(()=>{void load()},[load]);

  const selectedSource=workspace.sources.find(row=>row.id===form.sourceId);
  const selectedTarget=workspace.targets.find(row=>`${row.type}:${row.id}`===form.targetKey);
  const maximum=useMemo(()=>Math.max(0,Math.min(
    Number(selectedSource?.available_amount||0),Number(selectedTarget?.remaining_amount||0),Number(workspace.due||0)
  )),[selectedSource,selectedTarget,workspace.due]);

  function changeForm(patch){setForm(current=>({...current,...patch,commandId:""}));setError("");setOk("")}

  async function allocate(){
    const amount=Number(form.amount);
    if(!selectedSource||!selectedTarget)return setError("اختر السلفة والمستند المطلوب تسويته.");
    if(!Number.isFinite(amount)||amount<=0)return setError("أدخل مبلغ تخصيص أكبر من صفر.");
    if(amount>maximum)return setError(`الحد الأقصى المتاح لهذا التخصيص هو ${money(maximum)}.`);
    const commandId=form.commandId||nextCommandId();
    if(!form.commandId)setForm(current=>({...current,commandId}));
    setBusy(true);setError("");setOk("");
    const name=partyType==="customer"?"allocate_customer_advance":"allocate_supplier_advance";
    const args=partyType==="customer"
      ?{source_receipt:selectedSource.id,target_type:selectedTarget.type,target_id:selectedTarget.id,allocation_amount:amount,command_id:commandId}
      :{source_payment:selectedSource.id,target_type:selectedTarget.type,target_id:selectedTarget.id,allocation_amount:amount,command_id:commandId};
    const result=await supabase.rpc(name,args);
    if(result.error)setError(friendlyError(result.error));
    else{
      setForm({sourceId:"",targetKey:"",amount:"",commandId:""});
      setOk("تم تخصيص السلفة للمستند وتحديث الرصيد مع حفظ أثر التدقيق.");
      await onChanged?.();await load();
    }
    setBusy(false);
  }

  function requestReverse(kind,row){setReason("");setError("");setAction({kind,row})}
  async function confirmReverse(){
    if(!action||!reason.trim())return;
    setBusy(true);setError("");setOk("");
    const result=action.kind==="allocation"
      ?await supabase.rpc("reverse_advance_allocation",{allocation_type:partyType,target_id:action.row.id,reason:reason.trim()})
      :await supabase.rpc("reverse_classified_cash_transaction",{
        transaction_type:partyType==="customer"?"customer_receipt":"supplier_payment",target_id:action.row.id,reason:reason.trim()
      });
    if(result.error)setError(friendlyError(result.error));
    else{
      setAction(null);setReason("");
      setOk(action.kind==="allocation"?"تم عكس تخصيص السلفة وإعادة المبلغ إلى الرصيد المتاح.":"تم عكس الحركة النقدية مع الحفاظ على سجلها.");
      await onChanged?.();await load();
    }
    setBusy(false);
  }

  if(loading)return <Notice>جارِ تحميل السلف والتخصيصات...</Notice>;
  const activeAllocations=workspace.allocations.filter(row=>row.status==="allocated");
  const historyAllocations=workspace.allocations.filter(row=>row.status!=="allocated");
  return <Panel title={partyType==="customer"?"السلف وتخصيص التحصيلات":"السلف وتخصيص الدفعات"}>
    <p style={{color:"var(--color-text-muted)",marginTop:0}}>المستحق الحالي {money(workspace.due)}. لا يغيّر التخصيص قيمة الحركة الأصلية؛ بل يربط جزء السلفة بمستند محدد ويحفظ الرابط في التدقيق.</p>
    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
    {workspace.sources.length>0&&workspace.targets.length>0&&Number(workspace.due)>0?<div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(190px,1fr))",gap:10,alignItems:"end"}}>
      <Field label="السلفة المتاحة"><select style={inputStyle} value={form.sourceId} onChange={event=>changeForm({sourceId:event.target.value})}><option value="">اختر</option>{workspace.sources.map(row=><option key={row.id} value={row.id}>{row.date} · متاح {money(row.available_amount)}</option>)}</select></Field>
      <Field label="المستند"><select style={inputStyle} value={form.targetKey} onChange={event=>changeForm({targetKey:event.target.value})}><option value="">اختر</option>{workspace.targets.map(row=><option key={`${row.type}:${row.id}`} value={`${row.type}:${row.id}`}>{row.label} · متبقي {money(row.remaining_amount)}</option>)}</select></Field>
      <Field label={`المبلغ${maximum?` — حد أقصى ${money(maximum)}`:""}`}><input style={inputStyle} type="number" min="0.01" max={maximum||undefined} step="any" value={form.amount} onChange={event=>changeForm({amount:event.target.value})}/></Field>
      <Button disabled={busy||maximum<=0} onClick={allocate}>{busy?"جارِ التخصيص...":"تخصيص السلفة"}</Button>
    </div>:<Notice>{Number(workspace.due)<=0?"لا يوجد مستحق يحتاج تخصيصًا الآن.":workspace.sources.length===0?"لا توجد سلفة متاحة غير مخصصة.":"لا توجد مستندات مؤهلة للتخصيص."}</Notice>}

    <details style={{marginTop:14}} open={activeAllocations.length>0}><summary>التخصيصات النشطة ({activeAllocations.length})</summary><div style={{display:"grid",gap:8,marginTop:8}}>{activeAllocations.map(row=><div key={row.id} style={{display:"flex",justifyContent:"space-between",gap:10,alignItems:"center",flexWrap:"wrap",padding:10,background:"var(--color-surface-muted)",borderRadius:9}}><span><strong>{row.target_label}</strong><small style={{display:"block"}}>{new Date(row.allocated_at).toLocaleString("ar-EG")}</small></span><strong>{money(row.amount)}</strong>{canReverse&&<Button tone="danger" disabled={busy} onClick={()=>requestReverse("allocation",row)}>عكس التخصيص</Button>}</div>)}{!activeAllocations.length&&<span>لا توجد تخصيصات نشطة.</span>}</div></details>

    <details style={{marginTop:12}}><summary>الحركات النقدية والتاريخ ({workspace.transactions.length})</summary><div style={{display:"grid",gap:8,marginTop:8}}>{workspace.transactions.map(row=><div key={row.id} style={{display:"flex",justifyContent:"space-between",gap:10,alignItems:"center",flexWrap:"wrap",padding:10,border:"1px solid var(--color-border)",borderRadius:9}}><span><strong>{CLASS_LABEL[row.classification]||row.classification}</strong><small style={{display:"block"}}>{row.date} · {STATUS_LABEL[row.status]||row.status}{row.reversal_reason?` · ${row.reversal_reason}`:""}</small></span><strong>{money(row.amount)}</strong>{canReverse&&row.status==="posted"&&<Button tone="danger" disabled={busy||row.has_active_allocations} onClick={()=>requestReverse("transaction",row)}>{row.has_active_allocations?"اعكس التخصيصات أولًا":"عكس الحركة"}</Button>}</div>)}{historyAllocations.map(row=><div key={row.id} style={{padding:10,border:"1px solid var(--color-border)",borderRadius:9}}><strong>تخصيص معكوس · {money(row.amount)}</strong><small style={{display:"block"}}>{row.reversal_reason||"بدون بيان"}</small></div>)}</div></details>

    <ConfirmDialog open={Boolean(action)} title={action?.kind==="allocation"?"عكس تخصيص السلفة":"عكس الحركة النقدية"} description="سيبقى السجل الأصلي محفوظًا، ويجب توثيق سبب العكس." confirmLabel="تأكيد العكس" danger busy={busy} reasonRequired reason={reason} onReasonChange={setReason} error={action&&error?error:""} onConfirm={confirmReverse} onCancel={()=>!busy&&setAction(null)}/>
  </Panel>;
}
