import React,{useCallback,useEffect,useMemo,useState}from"react";
import{RefreshCw}from"lucide-react";
import{supabase}from"../supabaseClient";
import{exportBalanceSheetReport,exportLedgerReport,exportProfitLossReport,exportTrialBalanceReport}from"./accountingExports";

const TYPE_LABELS={asset:"أصول",liability:"التزامات",equity:"حقوق ملكية",revenue:"إيرادات",cost_of_sales:"تكلفة مبيعات",expense:"مصروفات"};

function today(){return new Date().toISOString().slice(0,10)}
function yearStart(){const d=new Date();return `${d.getFullYear()}-01-01`}
function num(v){const n=Number(v||0);return Number.isFinite(n)?n:0}
function money(v){return new Intl.NumberFormat("ar-SA",{minimumFractionDigits:2,maximumFractionDigits:2}).format(num(v))}
function sideLabel(value){return value==="debit"?"مدين":value==="credit"?"دائن":"—"}

function Controls({children}){return <div className="accounting-report-controls">{children}</div>}
function Field({label,children}){return <label className="accounting-report-field"><span>{label}</span>{children}</label>}
function Empty({children}){return <div className="accounting-empty">{children}</div>}

function LedgerReport({accounts,projects,initialAccountId,onAccountConsumed}){
  const [filters,setFilters]=useState({account_id:initialAccountId||"",from:yearStart(),to:today(),project_id:""});
  const [report,setReport]=useState(null);
  const [state,setState]=useState({loading:false,error:""});

  useEffect(()=>{
    if(initialAccountId){
      setFilters((f)=>({...f,account_id:initialAccountId}));
      onAccountConsumed?.();
    }
  },[initialAccountId,onAccountConsumed]);

  const load=useCallback(async()=>{
    if(!filters.account_id){setReport(null);setState({loading:false,error:"اختر حسابًا أولًا."});return}
    setState({loading:true,error:""});
    const result=await supabase.rpc("get_accounting_account_ledger",{
      target_account:filters.account_id,
      date_from:filters.from||null,
      date_to:filters.to||null,
      target_project:filters.project_id||null,
    });
    if(result.error){setReport(null);setState({loading:false,error:result.error.message||"تعذر تحميل كشف الحساب."});return}
    setReport(result.data||null);setState({loading:false,error:""});
  },[filters]);

  useEffect(()=>{if(filters.account_id)void load()},[filters.account_id,load]);

  const tx=report?.transactions||[];
  return <section className="accounting-panel">
    <div className="accounting-report-heading"><div><h3>كشف حساب</h3><p>الحركات الفعلية على الحساب مع الرصيد الافتتاحي والجاري والمصدر.</p></div><div className="accounting-report-actions"><button type="button" className="accounting-button ghost" onClick={()=>exportLedgerReport(report,accounts.find((a)=>a.id===filters.account_id),filters)} disabled={!report}>تصدير Excel</button><button type="button" className="accounting-button ghost" onClick={load} disabled={state.loading}><RefreshCw size={14}/>تحديث</button></div></div>
    <Controls>
      <Field label="الحساب"><select value={filters.account_id} onChange={(e)=>setFilters((f)=>({...f,account_id:e.target.value}))}><option value="">اختر حسابًا</option>{accounts.map((a)=><option key={a.id} value={a.id}>{a.account_code} · {a.name_ar}{a.is_posting?"":" · تجميعي"}</option>)}</select></Field>
      <Field label="من"><input type="date" value={filters.from} onChange={(e)=>setFilters((f)=>({...f,from:e.target.value}))}/></Field>
      <Field label="إلى"><input type="date" value={filters.to} onChange={(e)=>setFilters((f)=>({...f,to:e.target.value}))}/></Field>
      <Field label="المشروع"><select value={filters.project_id} onChange={(e)=>setFilters((f)=>({...f,project_id:e.target.value}))}><option value="">كل المشاريع</option>{projects.map((p)=><option key={p.id} value={p.id}>{p.project_code||""} {p.project_name||p.name||""}</option>)}</select></Field>
    </Controls>

    {state.error&&<div className="accounting-notice error">{state.error}</div>}
    {state.loading?<Empty>جارِ تحميل كشف الحساب...</Empty>:report&&<>
      <div className="accounting-report-kpis">
        <div><span>الرصيد الافتتاحي</span><b>{money(report.opening_balance)}</b><small>{sideLabel(report.opening_side)}</small></div>
        <div><span>الرصيد الختامي</span><b>{money(report.closing_balance)}</b><small>{report.closing_raw>0?"مدين":report.closing_raw<0?"دائن":"—"}</small></div>
        <div><span>عدد الحركات</span><b>{tx.length}</b></div>
      </div>
      {tx.length===0?<Empty>لا توجد حركات على الحساب في الفترة المحددة.</Empty>:<div className="accounting-report-table-wrap"><table className="accounting-report-table">
        <thead><tr><th>التاريخ</th><th>القيد</th><th>البيان</th><th>المرجع</th><th>مدين</th><th>دائن</th><th>الرصيد الجاري</th><th>المصدر</th></tr></thead>
        <tbody>{tx.map((row)=><tr key={row.line_id}>
          <td>{row.entry_date}</td><td><b>{row.entry_number}</b>{row.master_overridden&&<small>Master Rev {row.revision_number}</small>}</td>
          <td>{row.line_description||row.journal_description||"—"}</td><td>{row.line_reference||row.journal_reference||"—"}</td>
          <td>{num(row.debit)?money(row.debit):"—"}</td><td>{num(row.credit)?money(row.credit):"—"}</td><td><b>{money(row.running_balance)}</b><small>{sideLabel(row.running_side)}</small></td>
          <td>{row.source_module?<><b>{row.source_module}</b><small>{row.source_record_id||"—"}</small></>:(row.entry_origin||"—")}</td>
        </tr>)}</tbody>
      </table></div>}
    </>}
  </section>;
}

function TrialBalanceReport({accounts,projects,onOpenLedger}){
  const [filters,setFilters]=useState({from:yearStart(),to:today(),account_id:"",account_type:"",project_id:""});
  const [report,setReport]=useState(null);
  const [state,setState]=useState({loading:true,error:""});

  const load=useCallback(async()=>{
    setState({loading:true,error:""});
    const result=await supabase.rpc("get_accounting_trial_balance",{
      date_from:filters.from||null,date_to:filters.to||null,
      target_account:filters.account_id||null,target_account_type:filters.account_type||null,
      target_project:filters.project_id||null,
    });
    if(result.error){setReport(null);setState({loading:false,error:result.error.message||"تعذر تحميل ميزان المراجعة."});return}
    setReport(result.data||null);setState({loading:false,error:""});
  },[filters]);

  useEffect(()=>{void load()},[load]);

  const rows=report?.rows||[];
  const t=report?.totals||{};
  return <section className="accounting-panel">
    <div className="accounting-report-heading"><div><h3>ميزان المراجعة</h3><p>الأرصدة الافتتاحية وحركة الفترة والأرصدة الختامية مع تجميع الحسابات الفرعية.</p></div><div className="accounting-report-actions"><button type="button" className="accounting-button ghost" onClick={()=>exportTrialBalanceReport(report,filters)} disabled={!report}>تصدير Excel</button><button type="button" className="accounting-button ghost" onClick={load} disabled={state.loading}><RefreshCw size={14}/>تحديث</button></div></div>
    <Controls>
      <Field label="من"><input type="date" value={filters.from} onChange={(e)=>setFilters((f)=>({...f,from:e.target.value}))}/></Field>
      <Field label="إلى"><input type="date" value={filters.to} onChange={(e)=>setFilters((f)=>({...f,to:e.target.value}))}/></Field>
      <Field label="الحساب"><select value={filters.account_id} onChange={(e)=>setFilters((f)=>({...f,account_id:e.target.value}))}><option value="">كل الحسابات</option>{accounts.map((a)=><option key={a.id} value={a.id}>{a.account_code} · {a.name_ar}</option>)}</select></Field>
      <Field label="النوع"><select value={filters.account_type} onChange={(e)=>setFilters((f)=>({...f,account_type:e.target.value}))}><option value="">كل الأنواع</option>{Object.entries(TYPE_LABELS).map(([k,v])=><option value={k} key={k}>{v}</option>)}</select></Field>
      <Field label="المشروع"><select value={filters.project_id} onChange={(e)=>setFilters((f)=>({...f,project_id:e.target.value}))}><option value="">كل المشاريع</option>{projects.map((p)=><option key={p.id} value={p.id}>{p.project_code||""} {p.project_name||p.name||""}</option>)}</select></Field>
    </Controls>
    {state.error&&<div className="accounting-notice error">{state.error}</div>}
    {state.loading?<Empty>جارِ تحميل ميزان المراجعة...</Empty>:<>
      <div className="accounting-report-balance-status">
        <span className={report?.full_gl_balanced?"ok":"bad"}>{report?.full_gl_balanced?"دفتر الأستاذ متزن":"يوجد فرق في دفتر الأستاذ"}</span>
        <span>حركة الفترة: مدين <b>{money(t.period_debit)}</b> · دائن <b>{money(t.period_credit)}</b></span>
      </div>
      {rows.length===0?<Empty>لا توجد أرصدة في النطاق المحدد.</Empty>:<div className="accounting-report-table-wrap"><table className="accounting-report-table trial">
        <thead><tr><th>الحساب</th><th>افتتاحي مدين</th><th>افتتاحي دائن</th><th>حركة مدين</th><th>حركة دائن</th><th>ختامي مدين</th><th>ختامي دائن</th></tr></thead>
        <tbody>{rows.map((row)=><tr key={row.id} className={row.is_posting?"":"group-row"}>
          <td><button type="button" className="accounting-report-account-link" style={{"--report-depth":Math.max(0,num(row.depth)-1)}} onClick={()=>onOpenLedger(row.id)}><b>{row.account_code}</b> · {row.name_ar}</button></td>
          <td>{money(row.opening_debit)}</td><td>{money(row.opening_credit)}</td><td>{money(row.period_debit)}</td><td>{money(row.period_credit)}</td><td>{money(row.closing_debit)}</td><td>{money(row.closing_credit)}</td>
        </tr>)}</tbody>
      </table></div>}
      <div className="accounting-report-note">إجماليات أعلى الجدول محسوبة من القيود المباشرة مرة واحدة؛ صفوف الحسابات التجميعية للعرض الهرمي فقط ولا تُجمع فوق الأبناء مرة ثانية.</div>
    </>}
  </section>;
}

function ProfitLossReport({projects,onOpenLedger}){
  const [filters,setFilters]=useState({from:yearStart(),to:today(),project_id:""});
  const [report,setReport]=useState(null);
  const [state,setState]=useState({loading:true,error:""});

  const load=useCallback(async()=>{
    setState({loading:true,error:""});
    const result=await supabase.rpc("get_accounting_profit_loss",{
      date_from:filters.from||null,
      date_to:filters.to||null,
      target_project:filters.project_id||null,
    });
    if(result.error){setReport(null);setState({loading:false,error:result.error.message||"تعذر تحميل قائمة الأرباح والخسائر."});return}
    setReport(result.data||null);setState({loading:false,error:""});
  },[filters]);

  useEffect(()=>{void load()},[load]);

  const rows=report?.rows||[];
  const summary=report?.summary||{};
  const groups=useMemo(()=>({
    revenue:rows.filter((r)=>r.account_type==="revenue"),
    cost_of_sales:rows.filter((r)=>r.account_type==="cost_of_sales"),
    expense:rows.filter((r)=>r.account_type==="expense"),
  }),[rows]);

  const renderRows=(type)=>groups[type].map((row)=><div className={"balance-sheet-row "+(row.is_posting?"":"group")} key={row.id}>
    <button type="button" onClick={()=>onOpenLedger(row.id)} style={{"--report-depth":Math.max(0,num(row.depth)-1)}}><span><b>{row.account_code}</b> · {row.name_ar}</span><strong>{money(row.amount)}</strong></button>
  </div>);

  return <section className="accounting-panel">
    <div className="accounting-report-heading"><div><h3>قائمة الأرباح والخسائر</h3><p>مشتقة مباشرة من القيود المرحّلة خلال الفترة المحددة، مع إمكانية التصفية حسب المشروع.</p></div><div className="accounting-report-actions"><button type="button" className="accounting-button ghost" onClick={()=>exportProfitLossReport(report,filters)} disabled={!report}>تصدير Excel</button><button type="button" className="accounting-button ghost" onClick={load} disabled={state.loading}><RefreshCw size={14}/>تحديث</button></div></div>
    <Controls>
      <Field label="من"><input type="date" value={filters.from} onChange={(e)=>setFilters((f)=>({...f,from:e.target.value}))}/></Field>
      <Field label="إلى"><input type="date" value={filters.to} onChange={(e)=>setFilters((f)=>({...f,to:e.target.value}))}/></Field>
      <Field label="المشروع"><select value={filters.project_id} onChange={(e)=>setFilters((f)=>({...f,project_id:e.target.value}))}><option value="">كل المشاريع</option>{projects.map((p)=><option key={p.id} value={p.id}>{p.project_code||""} {p.project_name||p.name||""}</option>)}</select></Field>
    </Controls>

    {state.error&&<div className="accounting-notice error">{state.error}</div>}
    {state.loading?<Empty>جارِ تحميل قائمة الأرباح والخسائر...</Empty>:report&&<>
      <div className="accounting-report-kpis">
        <div><span>الإيرادات</span><b>{money(summary.revenue)}</b></div>
        <div><span>تكلفة المبيعات</span><b>{money(summary.cost_of_sales)}</b></div>
        <div><span>مجمل الربح</span><b>{money(summary.gross_profit)}</b></div>
        <div><span>المصروفات</span><b>{money(summary.expenses)}</b></div>
        <div><span>صافي الربح / الخسارة</span><b>{money(summary.profit_loss)}</b></div>
      </div>

      <div className="balance-sheet-grid">
        <div className="balance-sheet-section"><h4>الإيرادات</h4>{groups.revenue.length?renderRows("revenue"):<Empty>لا توجد إيرادات في الفترة.</Empty>}<div className="balance-sheet-total"><span>إجمالي الإيرادات</span><b>{money(summary.revenue)}</b></div></div>
        <div className="balance-sheet-section"><h4>تكلفة المبيعات</h4>{groups.cost_of_sales.length?renderRows("cost_of_sales"):<Empty>لا توجد تكلفة مبيعات في الفترة.</Empty>}<div className="balance-sheet-total"><span>إجمالي تكلفة المبيعات</span><b>{money(summary.cost_of_sales)}</b></div></div>
        <div className="balance-sheet-section"><h4>المصروفات</h4>{groups.expense.length?renderRows("expense"):<Empty>لا توجد مصروفات في الفترة.</Empty>}<div className="balance-sheet-total"><span>إجمالي المصروفات</span><b>{money(summary.expenses)}</b></div></div>
      </div>

      <div className="balance-sheet-equation ok">
        <span>الإيرادات <b>{money(summary.revenue)}</b></span>
        <span>−</span>
        <span>تكلفة المبيعات <b>{money(summary.cost_of_sales)}</b></span>
        <span>−</span>
        <span>المصروفات <b>{money(summary.expenses)}</b></span>
        <span>=</span>
        <span>صافي الربح / الخسارة <b>{money(summary.profit_loss)}</b></span>
      </div>
      <div className="accounting-report-note">مجمل الربح = الإيرادات − تكلفة المبيعات. صافي الربح / الخسارة = مجمل الربح − المصروفات. صفوف الحسابات التجميعية للعرض فقط ولا تُجمع مرة ثانية في الإجماليات.</div>
    </>}
  </section>;
}

function BalanceSheetReport({onOpenLedger}){
  const [date,setDate]=useState(today());
  const [report,setReport]=useState(null);
  const [state,setState]=useState({loading:true,error:""});

  const load=useCallback(async()=>{
    setState({loading:true,error:""});
    const result=await supabase.rpc("get_accounting_balance_sheet",{as_of_date:date||null});
    if(result.error){setReport(null);setState({loading:false,error:result.error.message||"تعذر تحميل قائمة المركز المالي."});return}
    setReport(result.data||null);setState({loading:false,error:""});
  },[date]);

  useEffect(()=>{void load()},[load]);

  const rows=report?.rows||[];
  const cyplId=report?.current_year_profit_loss_mapping?.account_id||"";
  const groups=useMemo(()=>({
    asset:rows.filter((r)=>r.account_type==="asset"),
    liability:rows.filter((r)=>r.account_type==="liability"),
    equity:rows.filter((r)=>r.account_type==="equity"&&r.id!==cyplId),
  }),[rows,cyplId]);
  const s=report?.summary||{};
  const pl=report?.profit_loss||{};

  const renderRows=(type)=>groups[type].map((row)=><div className={"balance-sheet-row "+(row.is_posting?"":"group")} key={row.id}>
    <button type="button" onClick={()=>onOpenLedger(row.id)} style={{"--report-depth":Math.max(0,num(row.depth)-1)}}><span><b>{row.account_code}</b> · {row.name_ar}</span><strong>{money(row.amount)}</strong></button>
  </div>);

  return <section className="accounting-panel">
    <div className="accounting-report-heading"><div><h3>الميزانية / قائمة المركز المالي</h3><p>مشتقة مباشرة من دفتر الأستاذ حتى التاريخ المحدد، بدون تخزين إجماليات منفصلة.</p></div><div className="accounting-report-actions"><button type="button" className="accounting-button ghost" onClick={()=>exportBalanceSheetReport(report,date)} disabled={!report}>تصدير Excel</button><button type="button" className="accounting-button ghost" onClick={load} disabled={state.loading}><RefreshCw size={14}/>تحديث</button></div></div>
    <Controls><Field label="حتى تاريخ"><input type="date" value={date} onChange={(e)=>setDate(e.target.value)}/></Field></Controls>
    {state.error&&<div className="accounting-notice error">{state.error}</div>}
    {state.loading?<Empty>جارِ تحميل قائمة المركز المالي...</Empty>:report&&<>
      <div className="balance-sheet-grid">
        <div className="balance-sheet-section"><h4>الأصول</h4>{renderRows("asset")}<div className="balance-sheet-total"><span>إجمالي الأصول</span><b>{money(s.total_assets)}</b></div></div>
        <div className="balance-sheet-section"><h4>الالتزامات</h4>{renderRows("liability")}<div className="balance-sheet-total"><span>إجمالي الالتزامات</span><b>{money(s.total_liabilities)}</b></div></div>
        <div className="balance-sheet-section"><h4>حقوق الملكية</h4>{renderRows("equity")}<div className="balance-sheet-derived"><span>ربح / خسارة الفترة الحالية</span><b>{money(s.current_period_profit_loss)}</b></div><div className="balance-sheet-total"><span>إجمالي حقوق الملكية</span><b>{money(s.total_equity)}</b></div></div>
      </div>
      <div className="accounting-report-kpis">
        <div><span>الإيرادات</span><b>{money(pl.revenue)}</b></div>
        <div><span>تكلفة المبيعات</span><b>{money(pl.cost_of_sales)}</b></div>
        <div><span>المصروفات</span><b>{money(pl.expenses)}</b></div>
        <div><span>الربح / الخسارة</span><b>{money(pl.current_period_profit_loss)}</b></div>
      </div>
      <div className={"balance-sheet-equation "+(s.is_balanced?"ok":"bad")}>
        <span>الأصول <b>{money(s.total_assets)}</b></span><span>=</span><span>الالتزامات + حقوق الملكية <b>{money(s.total_liabilities_and_equity)}</b></span><span>الفرق <b>{money(s.difference)}</b></span>
      </div>
      <div className="accounting-report-note">بداية السنة المالية المستخدمة: {report.fiscal_start}. ربح/خسارة الفترة يُشتق من الإيرادات − تكلفة المبيعات − المصروفات ويظهر في حقوق الملكية مرة واحدة فقط.</div>
    </>}
  </section>;
}

export function AccountingReportsWorkspace({accounts=[],projects=[]}){
  const [reportTab,setReportTab]=useState("trial");
  const [ledgerAccount,setLedgerAccount]=useState("");

  const openLedger=(accountId)=>{setLedgerAccount(accountId);setReportTab("ledger")};

  return <div className="accounting-reports-workspace">
    <nav className="accounting-report-tabs" aria-label="التقارير المحاسبية">
      <button type="button" className={reportTab==="ledger"?"active":""} onClick={()=>setReportTab("ledger")}>كشف حساب</button>
      <button type="button" className={reportTab==="trial"?"active":""} onClick={()=>setReportTab("trial")}>ميزان المراجعة</button>
      <button type="button" className={reportTab==="balance"?"active":""} onClick={()=>setReportTab("balance")}>الميزانية</button>
      <button type="button" className={reportTab==="profitLoss"?"active":""} onClick={()=>setReportTab("profitLoss")}>الأرباح والخسائر</button>
    </nav>
    {reportTab==="ledger"&&<LedgerReport accounts={accounts} projects={projects} initialAccountId={ledgerAccount} onAccountConsumed={()=>setLedgerAccount("")}/>}
    {reportTab==="trial"&&<TrialBalanceReport accounts={accounts} projects={projects} onOpenLedger={openLedger}/>}
    {reportTab==="balance"&&<BalanceSheetReport onOpenLedger={openLedger}/>}
    {reportTab==="profitLoss"&&<ProfitLossReport projects={projects} onOpenLedger={openLedger}/>}
  </div>;
}
