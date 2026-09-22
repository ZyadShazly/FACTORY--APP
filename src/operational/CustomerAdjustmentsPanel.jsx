import React,{useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{Button,Field,Notice,Panel,inputStyle,money}from"./ui";
import{ConfirmDialog}from"../v22/shared";

const TYPE_LABEL={
  commercial_discount:"خصم تجاري",
  withholding_tax:"ضريبة استقطاع",
  retention:"حجز / Retention",
  bank_charge:"رسوم أو فرق بنكي",
  other:"تسوية أخرى",
};

export function CustomerAdjustmentsPanel({customerId,due=0,rows=[],canReverse=false,onChanged}){
  const[form,setForm]=useState({type:"commercial_discount",amount:"",date:new Date().toISOString().slice(0,10),reason:"",commandId:""});
  const[busy,setBusy]=useState(false);
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[reverse,setReverse]=useState(null);
  const[reverseReason,setReverseReason]=useState("");

  const customerRows=useMemo(
    ()=>rows.filter(row=>row.customer_id===customerId).sort((a,b)=>String(b.adjustment_date||"").localeCompare(String(a.adjustment_date||""))),
    [rows,customerId]
  );
  const posted=customerRows.filter(row=>row.status==="posted");

  function change(patch){setForm(current=>({...current,...patch,commandId:""}));setError("");setOk("")}

  async function save(){
    const amount=Number(form.amount);
    if(!Number.isFinite(amount)||amount<=0)return setError("أدخل مبلغ تسوية أكبر من صفر.");
    if(amount>Number(due||0))return setError(`مبلغ التسوية لا يمكن أن يتجاوز المستحق الحالي ${money(due)}.`);
    if(!form.reason.trim())return setError("اكتب سبب التسوية.");
    const commandId=form.commandId||globalThis.crypto.randomUUID();
    if(!form.commandId)setForm(current=>({...current,commandId}));
    setBusy(true);setError("");setOk("");
    const result=await supabase.rpc("record_customer_adjustment",{
      target_customer:customerId,
      adjustment_amount:amount,
      adjustment_kind:form.type,
      adjustment_reason:form.reason.trim(),
      adjusted_on:form.date,
      command_id:commandId,
    });
    setBusy(false);
    if(result.error)return setError(result.error.message);
    setForm({type:"commercial_discount",amount:"",date:new Date().toISOString().slice(0,10),reason:"",commandId:""});
    setOk("تم تسجيل التسوية غير النقدية وتخفيض رصيد العميل.");
    await onChanged?.();
  }

  async function confirmReverse(){
    if(!reverseReason.trim())return;
    setBusy(true);setError("");setOk("");
    const result=await supabase.rpc("reverse_customer_adjustment",{target_adjustment:reverse.id,reason:reverseReason.trim()});
    setBusy(false);
    if(result.error)return setError(result.error.message);
    setReverse(null);setReverseReason("");
    setOk("تم عكس التسوية وإعادة قيمتها إلى رصيد العميل.");
    await onChanged?.();
  }

  return <Panel title="تسويات وخصومات العميل">
    <p style={{color:"var(--color-text-muted)",marginTop:0}}>استخدمها فقط للمبالغ غير النقدية التي يخفضها العميل من المستحق، مثل خصم تجاري أو ضريبة استقطاع أو حجز. لا تُسجل كتحصيل نقدي.</p>
    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}
    {Number(due)>0&&<div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(180px,1fr))",gap:10,alignItems:"end"}}>
      <Field label="النوع"><select style={inputStyle} value={form.type} onChange={e=>change({type:e.target.value})}>{Object.entries(TYPE_LABEL).map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></Field>
      <Field label="المبلغ"><input style={inputStyle} type="number" min="0.01" max={due} step="0.01" value={form.amount} onChange={e=>change({amount:e.target.value})}/></Field>
      <Field label="التاريخ"><input style={inputStyle} type="date" value={form.date} onChange={e=>change({date:e.target.value})}/></Field>
      <Field label="السبب"><input style={inputStyle} value={form.reason} onChange={e=>change({reason:e.target.value})} placeholder="سبب الخصم أو التسوية"/></Field>
      <Button disabled={busy} onClick={save}>{busy?"جارِ الحفظ...":"تسجيل التسوية"}</Button>
    </div>}
    {Number(due)<=0&&<Notice>لا يوجد رصيد مستحق يمكن تخفيضه بتسوية غير نقدية.</Notice>}

    <details style={{marginTop:14}} open={posted.length>0}>
      <summary>سجل التسويات ({customerRows.length})</summary>
      <div style={{display:"grid",gap:8,marginTop:8}}>
        {customerRows.map(row=><div key={row.id} style={{display:"flex",justifyContent:"space-between",gap:10,alignItems:"center",flexWrap:"wrap",padding:10,border:"1px solid var(--color-border)",borderRadius:9}}>
          <span><strong>{TYPE_LABEL[row.adjustment_type]||row.adjustment_type}</strong><small style={{display:"block"}}>{row.adjustment_date} · {row.reason}{row.status==="reversed"?` · معكوسة: ${row.reversal_reason||"بدون بيان"}`:""}</small></span>
          <strong>{money(row.amount)}</strong>
          {canReverse&&row.status==="posted"&&<Button tone="danger" disabled={busy} onClick={()=>{setReverse(row);setReverseReason("");setError("")}}>عكس التسوية</Button>}
        </div>)}
        {!customerRows.length&&<span>لا توجد تسويات غير نقدية.</span>}
      </div>
    </details>

    <ConfirmDialog open={Boolean(reverse)} title="عكس تسوية العميل" description="ستبقى الحركة الأصلية محفوظة ويعود المبلغ إلى رصيد العميل." confirmLabel="تأكيد العكس" danger busy={busy} reasonRequired reason={reverseReason} onReasonChange={setReverseReason} onConfirm={confirmReverse} onCancel={()=>!busy&&setReverse(null)}/>
  </Panel>;
}
