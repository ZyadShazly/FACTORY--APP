import React,{useCallback,useEffect,useMemo,useState}from"react";
import{RefreshCw}from"lucide-react";
import{supabase}from"../supabaseClient";

const MODULE_LABELS={
  cash:"النقدية والتحصيلات والمدفوعات",
  sales:"المبيعات والعملاء",
  procurement:"المشتريات والموردون",
  inventory:"المخزون",
  rentals:"الإيجارات",
  expenses:"المصروفات",
  payroll:"الرواتب",
  daily_labor:"العمالة اليومية",
  production:"الإنتاج",
  opening:"الأرصدة الافتتاحية",
  reports:"التقارير المحاسبية",
};

export function AccountingMappingsWorkspace({accounts=[],profile}){
  const [workspace,setWorkspace]=useState({definitions:[],auto_posting_readiness:{}});
  const [drafts,setDrafts]=useState({});
  const [clearing,setClearing]=useState(null);
  const [state,setState]=useState({loading:true,busyKey:"",error:"",success:""});
  const isOwner=profile?.role==="owner";

  const load=useCallback(async()=>{
    setState((s)=>({...s,loading:true,error:""}));
    const result=await supabase.rpc("get_accounting_mapping_workspace");
    if(result.error){
      setWorkspace({definitions:[],auto_posting_readiness:{}});
      setState((s)=>({...s,loading:false,error:result.error.message||"تعذر تحميل ربط الحسابات."}));
      return;
    }
    const data=result.data||{};
    const definitions=Array.isArray(data.definitions)?data.definitions:[];
    setWorkspace({definitions,auto_posting_readiness:data.auto_posting_readiness||{}});
    setDrafts(Object.fromEntries(definitions.map((d)=>[d.mapping_key,d.mapping?.account_id||""])));
    setState((s)=>({...s,loading:false}));
  },[]);

  useEffect(()=>{void load()},[load]);

  const groups=useMemo(()=>{
    const map=new Map();
    for(const row of workspace.definitions){
      if(!map.has(row.module))map.set(row.module,[]);
      map.get(row.module).push(row);
    }
    return [...map.entries()];
  },[workspace.definitions]);

  const save=async(row)=>{
    const accountId=drafts[row.mapping_key]||"";
    if(!accountId){setState((s)=>({...s,error:"اختر حسابًا قبل الحفظ.",success:""}));return}
    setState((s)=>({...s,busyKey:row.mapping_key,error:"",success:""}));
    const result=await supabase.rpc("owner_set_accounting_mapping",{target_key:row.mapping_key,target_account:accountId});
    if(result.error){setState((s)=>({...s,busyKey:"",error:result.error.message||"تعذر حفظ الربط."}));return}
    await load();
    setState((s)=>({...s,busyKey:"",success:`تم ربط ${row.label_ar} بالحساب المختار.`}));
  };

  const clearMapping=async()=>{
    if(!clearing?.reason?.trim()){setState((s)=>({...s,error:"سبب إلغاء الربط مطلوب."}));return}
    setState((s)=>({...s,busyKey:clearing.row.mapping_key,error:"",success:""}));
    const result=await supabase.rpc("owner_clear_accounting_mapping",{target_key:clearing.row.mapping_key,reason:clearing.reason.trim()});
    if(result.error){setState((s)=>({...s,busyKey:"",error:result.error.message||"تعذر إلغاء الربط."}));return}
    const label=clearing.row.label_ar;
    setClearing(null);await load();
    setState((s)=>({...s,busyKey:"",success:`تم إلغاء ربط ${label}.`}));
  };

  const suggested=(row)=>row.suggested_account;
  const eligibleAccounts=(row)=>accounts.filter((a)=>a.is_active&&a.is_posting&&(row.expected_account_types||[]).includes(a.account_type));

  return <div className="mapping-workspace">
    <div className="accounting-stage-note">
      <span>الربط هنا يحدد أي حساب سيستخدمه الـGL لكل حدث مالي. لا توجد عملية تشغيلية تولّد قيودًا تلقائية حتى الآن.</span>
    </div>

    <section className="accounting-panel">
      <div className="accounting-report-heading">
        <div><h3>ربط الحسابات</h3><p>الحسابات المقترحة ليست إجبارية. يمكنك اختيار أي حساب حركة نشط من النوع الصحيح.</p></div>
        <button type="button" className="accounting-button ghost" onClick={load} disabled={state.loading}><RefreshCw size={14}/>تحديث</button>
      </div>

      {state.error&&<div className="accounting-notice error">{state.error}</div>}
      {state.success&&<div className="accounting-notice success">{state.success}</div>}
      {!isOwner&&<div className="accounting-notice">يمكنك مشاهدة الربط الحالي. التعديل متاح للـOwner / Master فقط.</div>}

      {state.loading?<div className="accounting-empty">جارِ تحميل خريطة الربط...</div>:groups.map(([module,rows])=><section className="mapping-module" key={module}>
        <div className="mapping-module-head">
          <div><h4>{MODULE_LABELS[module]||module}</h4><small>{workspace.auto_posting_readiness?.[module]?"الربط المطلوب لهذا الجزء مكتمل":"يوجد ربط مطلوب ناقص"}</small></div>
          <span className={"accounting-badge "+(workspace.auto_posting_readiness?.[module]?"active":"group")}>{workspace.auto_posting_readiness?.[module]?"جاهز للربط لاحقًا":"غير مكتمل"}</span>
        </div>
        <div className="mapping-list">{rows.map((row)=>{
          const current=row.mapping?.account;
          const suggestion=suggested(row);
          const eligible=eligibleAccounts(row);
          return <div className="mapping-row" key={row.mapping_key}>
            <div className="mapping-copy">
              <strong>{row.label_ar}</strong>
              <span>{row.description||row.label_en||row.mapping_key}</span>
              <small>Key: {row.mapping_key} · النوع المسموح: {(row.expected_account_types||[]).join(" / ")}</small>
            </div>
            <div className="mapping-current">
              {current?<><b>{current.account_code} · {current.name_ar}</b><small>{current.account_type}</small></>:<span>غير مربوط</span>}
            </div>
            <div className="mapping-editor">
              <select value={drafts[row.mapping_key]||""} disabled={!isOwner} onChange={(e)=>setDrafts((d)=>({...d,[row.mapping_key]:e.target.value}))}>
                <option value="">اختر حسابًا</option>
                {eligible.map((a)=><option key={a.id} value={a.id}>{a.account_code} · {a.name_ar}</option>)}
              </select>
              {isOwner&&suggestion&&eligible.some((a)=>a.id===suggestion.id)&&<button type="button" className="mapping-suggest" onClick={()=>setDrafts((d)=>({...d,[row.mapping_key]:suggestion.id}))}>المقترح: {suggestion.account_code}</button>}
            </div>
            <div className="mapping-actions">
              {isOwner&&<button type="button" className="accounting-button primary" disabled={state.busyKey===row.mapping_key||!drafts[row.mapping_key]} onClick={()=>save(row)}>حفظ الربط</button>}
              {isOwner&&current&&<button type="button" className="accounting-button ghost" disabled={state.busyKey===row.mapping_key} onClick={()=>setClearing({row,reason:""})}>إلغاء الربط</button>}
            </div>
          </div>;
        })}</div>
      </section>)}
    </section>

    {clearing&&<div className="accounting-modal-layer" role="dialog" aria-modal="true" aria-label="إلغاء ربط الحساب">
      <div className="accounting-modal compact">
        <div className="accounting-modal-head"><div><span>Owner / Master</span><h3>إلغاء ربط {clearing.row.label_ar}</h3></div><button type="button" className="accounting-close" onClick={()=>setClearing(null)}>×</button></div>
        <p>إلغاء الربط لا يغير أي قيد سابق. سيمنع فقط الاعتماد على هذا الربط في عمليات Auto-posting المستقبلية حتى يتم تعيين حساب جديد.</p>
        <label>سبب إلغاء الربط<textarea rows={4} value={clearing.reason} onChange={(e)=>setClearing((c)=>({...c,reason:e.target.value}))}/></label>
        <div className="accounting-modal-actions"><button type="button" className="accounting-button ghost" onClick={()=>setClearing(null)}>رجوع</button><button type="button" className="accounting-button primary" onClick={clearMapping} disabled={Boolean(state.busyKey)}>تأكيد</button></div>
      </div>
    </div>}
  </div>;
}
