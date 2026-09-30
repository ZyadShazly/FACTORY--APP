import React, { useCallback, useEffect, useMemo, useState } from "react";
import { supabase } from "../supabaseClient";

const STATUS_LABELS={draft:"مسودة",posted:"مرحّل",reversed:"معكوس"};
const ORIGIN_LABELS={manual:"يدوي",opening:"افتتاحي",system:"تلقائي",reversal:"عكسي"};

function today(){return new Date().toISOString().slice(0,10)}
function amount(value){const n=Number(value||0);return Number.isFinite(n)?n:0}
function money(value){return new Intl.NumberFormat("ar-SA",{minimumFractionDigits:2,maximumFractionDigits:2}).format(amount(value))}
function blankLine(){return{account_id:"",debit:"",credit:"",description:""}}
function blankEditor(){return{mode:"create",id:"",entry_origin:"manual",entry_date:today(),reference:"",description:"",lines:[blankLine(),blankLine()],edit_reason:"",legacy_account_ids:[]}}

function editorFromJournal(row,mode){
  return{
    mode,id:row.id,entry_origin:row.entry_origin,entry_date:row.entry_date||today(),
    reference:row.reference||"",description:row.description||"",
    lines:(row.lines||[]).map((line)=>({
      account_id:line.account_id||"",debit:String(line.debit||""),credit:String(line.credit||""),
      description:line.description||"",
    })),
    edit_reason:"",
    legacy_account_ids:[...new Set((row.lines||[]).map((line)=>line.account_id).filter(Boolean))],
  };
}

function JournalEditor({editor,accounts,busy,onChange,onClose,onSave}){
  const totals=useMemo(()=>editor.lines.reduce((acc,line)=>({
    debit:acc.debit+amount(line.debit),credit:acc.credit+amount(line.credit),
  }),{debit:0,credit:0}),[editor.lines]);
  const patchLine=(index,patch)=>onChange({lines:editor.lines.map((line,i)=>i===index?{...line,...patch}:line)});
  const removeLine=(index)=>onChange({lines:editor.lines.filter((_,i)=>i!==index)});
  const addLine=()=>onChange({lines:[...editor.lines,blankLine()]});
  const isPostedEdit=editor.mode==="posted-edit";

  return <div className="accounting-modal-layer" role="dialog" aria-modal="true" aria-label={isPostedEdit?"تعديل قيد مرحّل":"تحرير قيد"}>
    <div className="accounting-modal journal-modal">
      <div className="accounting-modal-head">
        <div><span>{isPostedEdit?"Owner / Master":"دفتر الأستاذ"}</span><h3>{editor.mode==="create"?"قيد جديد":isPostedEdit?"تعديل قيد مرحّل":"تعديل المسودة"}</h3></div>
        <button type="button" className="accounting-close" onClick={onClose}>×</button>
      </div>
      <div className="accounting-form-grid">
        <label>تاريخ القيد<input type="date" value={editor.entry_date} onChange={(e)=>onChange({entry_date:e.target.value})}/></label>
        <label>المرجع<input value={editor.reference} onChange={(e)=>onChange({reference:e.target.value})}/></label>
        {editor.mode==="create"&&<label>نوع القيد<select value={editor.entry_origin} onChange={(e)=>onChange({entry_origin:e.target.value})}><option value="manual">يدوي</option><option value="opening">افتتاحي — Owner فقط</option></select></label>}
        <label className="accounting-span-2">البيان<input value={editor.description} onChange={(e)=>onChange({description:e.target.value})}/></label>
      </div>

      <div className="journal-lines-editor">
        <div className="journal-lines-head"><strong>أطراف القيد</strong><button type="button" className="accounting-button ghost" onClick={addLine}>+ سطر</button></div>
        {editor.lines.map((line,index)=><div className="journal-line-row" key={index}>
          <select aria-label={"حساب السطر "+(index+1)} value={line.account_id} onChange={(e)=>patchLine(index,{account_id:e.target.value})}>
            <option value="">اختر الحساب</option>
            {accounts.map((account)=>{
              const allowed=Boolean(account.is_active&&account.is_posting)||editor.legacy_account_ids.includes(account.id);
              return <option key={account.id} value={account.id} disabled={!allowed}>{account.account_code} · {account.name_ar}{allowed?"":" — غير متاح للقيود الجديدة"}</option>;
            })}
          </select>
          <input aria-label={"مدين السطر "+(index+1)} type="number" min="0" step="0.01" placeholder="مدين" value={line.debit} onChange={(e)=>patchLine(index,{debit:e.target.value,credit:e.target.value?"":line.credit})}/>
          <input aria-label={"دائن السطر "+(index+1)} type="number" min="0" step="0.01" placeholder="دائن" value={line.credit} onChange={(e)=>patchLine(index,{credit:e.target.value,debit:e.target.value?"":line.debit})}/>
          <input aria-label={"بيان السطر "+(index+1)} placeholder="بيان السطر" value={line.description} onChange={(e)=>patchLine(index,{description:e.target.value})}/>
          <button type="button" className="journal-remove-line" onClick={()=>removeLine(index)} disabled={editor.lines.length<=2}>×</button>
        </div>)}
      </div>

      <div className="journal-balance-strip">
        <span>إجمالي المدين <b>{money(totals.debit)}</b></span>
        <span>إجمالي الدائن <b>{money(totals.credit)}</b></span>
        <span className={Math.abs(totals.debit-totals.credit)<0.005?"balanced":"unbalanced"}>الفرق <b>{money(Math.abs(totals.debit-totals.credit))}</b></span>
      </div>

      {isPostedEdit&&<label className="journal-edit-reason">سبب تعديل القيد المرحّل
        <textarea rows={3} value={editor.edit_reason} onChange={(e)=>onChange({edit_reason:e.target.value})} placeholder="سبب واضح وإلزامي للـAudit"/>
      </label>}

      <div className="accounting-modal-actions">
        <button type="button" className="accounting-button ghost" onClick={onClose}>رجوع</button>
        <button type="button" className="accounting-button primary" disabled={busy} onClick={onSave}>{busy?"جارِ الحفظ...":"حفظ"}</button>
      </div>
    </div>
  </div>;
}

export function JournalWorkspace({accounts,profile,permissions,focusJournalId="",onFocusConsumed}){
  const [filters,setFilters]=useState({from:"",to:""});
  const [workspace,setWorkspace]=useState({settings:{},periods:[],journals:[]});
  const [editor,setEditor]=useState(null);
  const [reverse,setReverse]=useState(null);
  const [settingsDraft,setSettingsDraft]=useState({activation_date:"",enabled:false});
  const [periodDraft,setPeriodDraft]=useState({start:"",end:""});
  const [periodAction,setPeriodAction]=useState(null);
  const [sourceTrace,setSourceTrace]=useState(null);
  const [state,setState]=useState({loading:true,busy:false,error:"",success:""});

  const isOwner=profile?.role==="owner";
  const canCreate=Boolean(permissions?.accounting_journal_create);
  const canPost=Boolean(permissions?.accounting_journal_post);
  const canReverse=Boolean(permissions?.accounting_journal_reverse);
  const canMasterEdit=isOwner&&Boolean(permissions?.accounting_journal_edit_posted);

  const load=useCallback(async()=>{
    setState((s)=>({...s,loading:true,error:""}));
    const result=await supabase.rpc("get_accounting_journal_workspace",{date_from:filters.from||null,date_to:filters.to||null});
    if(result.error){
      setState((s)=>({...s,loading:false,error:result.error.message||"تعذر تحميل القيود."}));
      return;
    }
    const data=result.data||{};
    setWorkspace({settings:data.settings||{},periods:Array.isArray(data.periods)?data.periods:[],journals:Array.isArray(data.journals)?data.journals:[]});
    setSettingsDraft({activation_date:data.settings?.activation_date||"",enabled:Boolean(data.settings?.enabled)});
    setState((s)=>({...s,loading:false}));
  },[filters.from,filters.to]);

  useEffect(()=>{void load()},[load]);

  useEffect(()=>{
    if(!focusJournalId||state.loading)return;
    const details=document.getElementById("journal-details-"+focusJournalId);
    const card=document.getElementById("journal-"+focusJournalId);
    if(details)details.open=true;
    if(card){
      card.scrollIntoView({behavior:"smooth",block:"center"});
      card.classList.add("focused");
      window.setTimeout(()=>card.classList.remove("focused"),1800);
    }
    onFocusConsumed?.();
  },[focusJournalId,state.loading,workspace.journals,onFocusConsumed]);

  const openSourceTrace=async(row)=>{
    setSourceTrace({loading:true,error:"",data:null,journal:row});
    const result=await supabase.rpc("get_accounting_source_trace",{target_journal:row.id});
    if(result.error){
      setSourceTrace({loading:false,error:result.error.message||"تعذر تحميل العملية الأصلية.",data:null,journal:row});
      return;
    }
    setSourceTrace({loading:false,error:"",data:result.data||{},journal:row});
  };

  const patchEditor=(patch)=>setEditor((current)=>({...current,...patch}));

  const saveEditor=async()=>{
    if(!editor?.description?.trim()){
      setState((s)=>({...s,error:"بيان القيد مطلوب."}));return;
    }
    if(editor.lines.length<2||editor.lines.some((line)=>!line.account_id)){
      setState((s)=>({...s,error:"القيد يحتاج سطرين على الأقل وكل سطر يجب أن يحتوي حسابًا."}));return;
    }
    for(const line of editor.lines){
      const d=amount(line.debit),c=amount(line.credit);
      if(!((d>0&&c===0)||(c>0&&d===0))){
        setState((s)=>({...s,error:"كل سطر يجب أن يحتوي قيمة في المدين أو الدائن فقط."}));return;
      }
    }
    if(editor.mode==="posted-edit"&&!editor.edit_reason.trim()){
      setState((s)=>({...s,error:"سبب تعديل القيد المرحّل مطلوب."}));return;
    }

    const payload={
      entry_date:editor.entry_date,reference:editor.reference.trim()||null,
      description:editor.description.trim(),
      ...(editor.mode==="create"?{entry_origin:editor.entry_origin}:{}),
      lines:editor.lines.map((line)=>({
        account_id:line.account_id,debit:amount(line.debit),credit:amount(line.credit),
        description:line.description.trim()||null,
      })),
    };

    setState((s)=>({...s,busy:true,error:"",success:""}));
    let result;
    if(editor.mode==="create") result=await supabase.rpc("create_accounting_journal",{payload});
    else if(editor.mode==="draft-edit") result=await supabase.rpc("update_accounting_journal_draft",{target_id:editor.id,payload});
    else result=await supabase.rpc("owner_edit_posted_accounting_journal",{target_id:editor.id,payload,edit_reason:editor.edit_reason.trim()});

    if(result.error){setState((s)=>({...s,busy:false,error:result.error.message||"تعذر حفظ القيد."}));return}
    setEditor(null);
    await load();
    setState((s)=>({...s,busy:false,success:editor.mode==="posted-edit"?"تم تعديل القيد المرحّل وتحديث أرصدة دفتر الأستاذ.":"تم حفظ القيد."}));
  };

  const postJournal=async(row)=>{
    setState((s)=>({...s,busy:true,error:"",success:""}));
    const result=await supabase.rpc("post_accounting_journal",{target_id:row.id});
    if(result.error){setState((s)=>({...s,busy:false,error:result.error.message||"تعذر ترحيل القيد."}));return}
    await load();setState((s)=>({...s,busy:false,success:"تم ترحيل القيد إلى دفتر الأستاذ."}));
  };

  const reverseJournal=async()=>{
    if(!reverse?.reason?.trim()){setState((s)=>({...s,error:"سبب العكس مطلوب."}));return}
    setState((s)=>({...s,busy:true,error:"",success:""}));
    const result=await supabase.rpc("reverse_accounting_journal",{target_id:reverse.row.id,reversal_date:reverse.date||today(),reason:reverse.reason.trim()});
    if(result.error){setState((s)=>({...s,busy:false,error:result.error.message||"تعذر عكس القيد."}));return}
    setReverse(null);await load();setState((s)=>({...s,busy:false,success:"تم إنشاء قيد عكسي من آخر شكل فعلي للقيد."}));
  };

  const saveSettings=async()=>{
    if(!isOwner)return;
    setState((s)=>({...s,busy:true,error:"",success:""}));
    const result=await supabase.rpc("owner_configure_accounting",{target_activation_date:settingsDraft.activation_date||null,target_enabled:Boolean(settingsDraft.enabled)});
    if(result.error){setState((s)=>({...s,busy:false,error:result.error.message||"تعذر تحديث إعدادات المحاسبة."}));return}
    await load();setState((s)=>({...s,busy:false,success:"تم تحديث إعدادات المحاسبة."}));
  };

  const createPeriod=async()=>{
    if(!periodDraft.start||!periodDraft.end){setState((s)=>({...s,error:"تاريخ بداية ونهاية الفترة مطلوبان."}));return}
    setState((s)=>({...s,busy:true,error:"",success:""}));
    const result=await supabase.rpc("owner_create_accounting_period",{target_start:periodDraft.start,target_end:periodDraft.end});
    if(result.error){setState((s)=>({...s,busy:false,error:result.error.message||"تعذر إنشاء الفترة."}));return}
    setPeriodDraft({start:"",end:""});await load();setState((s)=>({...s,busy:false,success:"تم إنشاء الفترة المحاسبية."}));
  };

  const applyPeriodAction=async()=>{
    if(!periodAction?.reason?.trim()){setState((s)=>({...s,error:"سبب الإجراء مطلوب."}));return}
    const rpc=periodAction.mode==="lock"?"owner_lock_accounting_period":"owner_reopen_accounting_period";
    setState((s)=>({...s,busy:true,error:"",success:""}));
    const result=await supabase.rpc(rpc,{target_id:periodAction.row.id,reason:periodAction.reason.trim()});
    if(result.error){setState((s)=>({...s,busy:false,error:result.error.message||"تعذر تحديث الفترة."}));return}
    setPeriodAction(null);await load();setState((s)=>({...s,busy:false,success:periodAction.mode==="lock"?"تم قفل الفترة.":"تم إعادة فتح الفترة."}));
  };

  return <div className="journal-workspace">
    <div className="accounting-stage-note">
      <span>دفتر الأستاذ مرتبط بالعمليات التشغيلية المفعّلة محاسبيًا، وكل قيد تلقائي يحتفظ بمرجع العملية الأصلية للمراجعة.</span>
    </div>

    {isOwner&&<section className="accounting-panel">
      <div className="journal-section-title"><div><h3>إعداد التفعيل والفترات</h3><p>تاريخ التفعيل والفترات المفتوحة يتحكمان في القيود اليدوية والتلقائية من العمليات المتكاملة.</p></div></div>
      <div className="journal-settings-grid">
        <label>تاريخ بدء المحاسبة<input type="date" value={settingsDraft.activation_date} onChange={(e)=>setSettingsDraft((s)=>({...s,activation_date:e.target.value}))}/></label>
        <label className="accounting-check"><input type="checkbox" checked={settingsDraft.enabled} onChange={(e)=>setSettingsDraft((s)=>({...s,enabled:e.target.checked}))}/><span>السماح بترحيل القيود</span></label>
        <button type="button" className="accounting-button primary" disabled={state.busy} onClick={saveSettings}>حفظ الإعدادات</button>
      </div>
      <div className="journal-period-create">
        <label>من<input type="date" value={periodDraft.start} onChange={(e)=>setPeriodDraft((s)=>({...s,start:e.target.value}))}/></label>
        <label>إلى<input type="date" value={periodDraft.end} onChange={(e)=>setPeriodDraft((s)=>({...s,end:e.target.value}))}/></label>
        <button type="button" className="accounting-button ghost" disabled={state.busy} onClick={createPeriod}>+ إنشاء فترة</button>
      </div>
      <div className="journal-period-list">{workspace.periods.map((period)=><div className="journal-period-row" key={period.id}>
        <span><b>{period.period_start}</b> → <b>{period.period_end}</b></span>
        <span className={"accounting-badge "+(period.status==="open"?"active":"disabled")}>{period.status==="open"?"مفتوحة":"مقفلة"}</span>
        <button type="button" className="accounting-button ghost" onClick={()=>setPeriodAction({mode:period.status==="open"?"lock":"reopen",row:period,reason:""})}>{period.status==="open"?"قفل":"إعادة فتح"}</button>
      </div>)}</div>
    </section>}

    <section className="accounting-panel">
      <div className="journal-toolbar">
        <div className="journal-filters">
          <label>من<input type="date" value={filters.from} onChange={(e)=>setFilters((f)=>({...f,from:e.target.value}))}/></label>
          <label>إلى<input type="date" value={filters.to} onChange={(e)=>setFilters((f)=>({...f,to:e.target.value}))}/></label>
          <button type="button" className="accounting-button ghost" onClick={load} disabled={state.loading}>تحديث</button>
        </div>
        {canCreate&&<button type="button" className="accounting-button primary" onClick={()=>setEditor(blankEditor())}>+ قيد جديد</button>}
      </div>

      {state.error&&<div className="accounting-notice error">{state.error}</div>}
      {state.success&&<div className="accounting-notice success">{state.success}</div>}
      {!workspace.settings?.enabled&&<div className="accounting-notice">الترحيل متوقف حاليًا. يمكن حفظ مسودات، لكن لا يمكن ترحيلها قبل تفعيل المحاسبة وفتح فترة.</div>}

      {state.loading?<div className="accounting-empty">جارِ تحميل القيود...</div>:workspace.journals.length===0?<div className="accounting-empty">لا توجد قيود في الفترة المحددة.</div>:<div className="journal-list">
        {workspace.journals.map((row)=><article id={"journal-"+row.id} className="journal-card" key={row.id}>
          <div className="journal-card-head">
            <div><strong>{row.entry_number}</strong><span>{row.entry_date} · {ORIGIN_LABELS[row.entry_origin]||row.entry_origin}</span></div>
            <span className={"accounting-badge "+(row.status==="posted"?"active":row.status==="reversed"?"disabled":"group")}>{STATUS_LABELS[row.status]||row.status}</span>
          </div>
          <p>{row.description}</p>
          <div className="journal-card-totals"><span>مدين <b>{money(row.total_debit)}</b></span><span>دائن <b>{money(row.total_credit)}</b></span>{row.master_overridden&&<span className="accounting-badge group">تعديل Master · Rev {row.revision_number}</span>}</div>
          <details id={"journal-details-"+row.id}><summary>عرض الأطراف والمصدر</summary>
            <div className="journal-lines-view">{(row.lines||[]).map((line)=><div key={line.id||line.line_number}>
              <span>{accounts.find((a)=>a.id===line.account_id)?.account_code||"—"} · {accounts.find((a)=>a.id===line.account_id)?.name_ar||"حساب"}</span>
              <span>{amount(line.debit)>0?"مدين "+money(line.debit):"دائن "+money(line.credit)}</span>
            </div>)}</div>
            {(row.source_module||row.source_record_id)&&<div className="journal-source">
              <span>المصدر: {row.source_module||"—"} · {row.source_event||"—"} · {row.source_record_id||"—"}</span>
              <button type="button" className="accounting-link-button" onClick={()=>openSourceTrace(row)}>عرض العملية الأصلية</button>
            </div>}
          </details>
          <div className="accounting-row-actions">
            {row.status==="draft"&&canCreate&&<button type="button" onClick={()=>setEditor(editorFromJournal(row,"draft-edit"))}>تعديل المسودة</button>}
            {row.status==="draft"&&canPost&&<button type="button" onClick={()=>postJournal(row)} disabled={state.busy||!workspace.settings?.enabled}>ترحيل</button>}
            {row.status==="posted"&&canMasterEdit&&<button type="button" onClick={()=>setEditor(editorFromJournal(row,"posted-edit"))}>تعديل Master</button>}
            {row.status==="posted"&&canReverse&&row.entry_origin!=="system"&&row.entry_origin!=="reversal"&&<button type="button" onClick={()=>setReverse({row,date:today(),reason:""})}>عكس القيد</button>}
          </div>
        </article>)}
      </div>}
    </section>

    {editor&&<JournalEditor editor={editor} accounts={accounts} busy={state.busy} onChange={patchEditor} onClose={()=>setEditor(null)} onSave={saveEditor}/>}

    {reverse&&<div className="accounting-modal-layer" role="dialog" aria-modal="true" aria-label="عكس القيد">
      <div className="accounting-modal compact">
        <div className="accounting-modal-head"><div><span>{reverse.row.entry_number}</span><h3>عكس القيد</h3></div><button type="button" className="accounting-close" onClick={()=>setReverse(null)}>×</button></div>
        <div className="accounting-form-grid">
          <label>تاريخ العكس<input type="date" value={reverse.date} onChange={(e)=>setReverse((r)=>({...r,date:e.target.value}))}/></label>
          <label className="accounting-span-2">سبب العكس<textarea rows={4} value={reverse.reason} onChange={(e)=>setReverse((r)=>({...r,reason:e.target.value}))}/></label>
        </div>
        <div className="accounting-modal-actions"><button type="button" className="accounting-button ghost" onClick={()=>setReverse(null)}>رجوع</button><button type="button" className="accounting-button primary" disabled={state.busy} onClick={reverseJournal}>تأكيد العكس</button></div>
      </div>
    </div>}

    {sourceTrace&&<div className="accounting-modal-layer" role="dialog" aria-modal="true" aria-label="العملية الأصلية للقيد">
      <div className="accounting-modal source-trace-modal">
        <div className="accounting-modal-head">
          <div><span>{sourceTrace.journal?.entry_number||"القيد"}</span><h3>العملية الأصلية</h3></div>
          <button type="button" className="accounting-close" onClick={()=>setSourceTrace(null)}>×</button>
        </div>
        {sourceTrace.loading?<div className="accounting-empty">جارِ تحميل العملية الأصلية...</div>:
         sourceTrace.error?<div className="accounting-notice error">{sourceTrace.error}</div>:
         !sourceTrace.data?.available?<div className="accounting-notice">{sourceTrace.data?.reason||"لا يوجد مصدر تشغيلي لهذا القيد."}</div>:
         <>
           <div className="source-trace-meta">
             <span><b>الموديول:</b> {sourceTrace.data.source_module}</span>
             <span><b>الحدث:</b> {sourceTrace.data.source_event}</span>
             <span><b>الجدول:</b> {sourceTrace.data.source_table}</span>
             <span><b>Record ID:</b> {sourceTrace.data.source_record_id}</span>
           </div>
           <div className="source-trace-fields">
             {Object.entries(sourceTrace.data.record||{}).filter(([,value])=>value!==null&&typeof value!=="object").slice(0,40).map(([key,value])=>
               <div key={key}><span>{key}</span><b>{String(value)}</b></div>
             )}
           </div>
         </>}
        <div className="accounting-modal-actions"><button type="button" className="accounting-button ghost" onClick={()=>setSourceTrace(null)}>إغلاق</button></div>
      </div>
    </div>}

    {periodAction&&<div className="accounting-modal-layer" role="dialog" aria-modal="true" aria-label="تحديث الفترة المحاسبية">
      <div className="accounting-modal compact">
        <div className="accounting-modal-head"><div><span>{periodAction.row.period_start} → {periodAction.row.period_end}</span><h3>{periodAction.mode==="lock"?"قفل الفترة":"إعادة فتح الفترة"}</h3></div><button type="button" className="accounting-close" onClick={()=>setPeriodAction(null)}>×</button></div>
        <label>السبب<textarea rows={4} value={periodAction.reason} onChange={(e)=>setPeriodAction((p)=>({...p,reason:e.target.value}))}/></label>
        <div className="accounting-modal-actions"><button type="button" className="accounting-button ghost" onClick={()=>setPeriodAction(null)}>رجوع</button><button type="button" className="accounting-button primary" disabled={state.busy} onClick={applyPeriodAction}>تأكيد</button></div>
      </div>
    </div>}
  </div>;
}
