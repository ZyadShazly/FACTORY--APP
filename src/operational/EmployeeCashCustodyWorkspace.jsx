import React,{useEffect,useMemo,useState}from"react";
import{supabase}from"../supabaseClient";
import{Button,Field,Notice,Panel,friendlyError,inputStyle,money}from"./ui";

const today=()=>{const d=new Date();const local=new Date(d.getTime()-d.getTimezoneOffset()*60000);return local.toISOString().slice(0,10)};
const emptyWorkspace={custodies:[],settlements:[],returns:[],employees:[],projects:[],cash_bank_accounts:[]};
const statusLabel={open:"مفتوحة",partially_settled:"مسوّاة جزئيًا",settled:"مقفلة"};
const grid={display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(190px,1fr))",gap:10,alignItems:"end"};
const tableStyle={width:"100%",borderCollapse:"collapse",fontSize:13};
const cell={padding:"9px 8px",borderBottom:"1px solid var(--color-border)",textAlign:"right",verticalAlign:"top"};

function Select({value,onChange,children,disabled=false}){return <select style={inputStyle} value={value} onChange={onChange} disabled={disabled}>{children}</select>}
function Input(props){return <input style={inputStyle}{...props}/>}

export function EmployeeCashCustodyWorkspace(){
  const[workspace,setWorkspace]=useState(emptyWorkspace);
  const[loading,setLoading]=useState(true);
  const[busy,setBusy]=useState("");
  const[error,setError]=useState("");
  const[ok,setOk]=useState("");
  const[issue,setIssue]=useState({employeeId:"",projectId:"",amount:"",date:today(),accountId:"",notes:"",commandId:""});
  const[settlement,setSettlement]=useState(null);
  const[returnForm,setReturnForm]=useState(null);

  async function load(){
    setLoading(true);
    const result=await supabase.rpc("get_employee_cash_custody_workspace");
    if(result.error)setError(friendlyError(result.error));else setWorkspace({...emptyWorkspace,...(result.data||{})});
    setLoading(false);
  }
  useEffect(()=>{void load()},[]);

  const openCustodies=useMemo(()=>workspace.custodies.filter(row=>row.status!=="settled"),[workspace]);
  const closedCustodies=useMemo(()=>workspace.custodies.filter(row=>row.status==="settled"),[workspace]);

  async function submitIssue(){
    setError("");setOk("");
    const amount=Number(issue.amount);
    if(!issue.employeeId)return setError("اختر الموظف.");
    if(!Number.isFinite(amount)||amount<=0)return setError("أدخل مبلغ عهدة أكبر من صفر.");
    if(!issue.accountId)return setError("اختر حساب صرف العهدة (بنك أو خزينة).");
    const commandId=issue.commandId||globalThis.crypto.randomUUID();
    if(!issue.commandId)setIssue(current=>({...current,commandId}));
    setBusy("issue");
    const result=await supabase.rpc("record_employee_cash_custody",{
      target_employee:issue.employeeId,advance_amount:amount,issued_on:issue.date,
      cash_bank_account:issue.accountId,target_project:issue.projectId||null,
      custody_notes:issue.notes.trim()||null,command_id:commandId,
    });
    setBusy("");
    if(result.error)return setError(friendlyError(result.error));
    setIssue({employeeId:"",projectId:"",amount:"",date:today(),accountId:"",notes:"",commandId:""});
    setOk("تم صرف العهدة "+(result.data?.custody_number||"")+" وتسجيل القيد المحاسبي.");
    await load();
  }

  function openSettlement(row){
    setSettlement({custodyId:row.id,custodyNumber:row.custody_number,employeeName:row.employee_name,remaining:Number(row.remaining_amount||0),amount:"",category:"مصروفات أخرى",date:today(),notes:"",commandId:""});
    setReturnForm(null);setError("");setOk("");
  }
  async function submitSettlement(){
    setError("");setOk("");
    const amount=Number(settlement.amount);
    if(!Number.isFinite(amount)||amount<=0)return setError("أدخل مبلغ مصروف أكبر من صفر.");
    if(amount>settlement.remaining)return setError("مبلغ التسوية أكبر من رصيد العهدة المتبقي.");
    if(!settlement.category.trim())return setError("اكتب بند المصروف.");
    const commandId=settlement.commandId||globalThis.crypto.randomUUID();
    if(!settlement.commandId)setSettlement(current=>({...current,commandId}));
    setBusy("settlement");
    const result=await supabase.rpc("record_employee_cash_custody_settlement",{
      target_custody:settlement.custodyId,expense_amount:amount,expense_category:settlement.category.trim(),
      settled_on:settlement.date,expense_notes:settlement.notes.trim()||null,command_id:commandId,
    });
    setBusy("");
    if(result.error)return setError(friendlyError(result.error));
    setSettlement(null);setOk("تم اعتماد مصروف العهدة وتخفيض رصيد الموظف.");
    await load();
  }

  function openReturn(row){
    setReturnForm({custodyId:row.id,custodyNumber:row.custody_number,employeeName:row.employee_name,remaining:Number(row.remaining_amount||0),amount:"",date:today(),accountId:"",notes:"",commandId:""});
    setSettlement(null);setError("");setOk("");
  }
  async function submitReturn(){
    setError("");setOk("");
    const amount=Number(returnForm.amount);
    if(!Number.isFinite(amount)||amount<=0)return setError("أدخل مبلغ مردود أكبر من صفر.");
    if(amount>returnForm.remaining)return setError("المبلغ المردود أكبر من رصيد العهدة المتبقي.");
    if(!returnForm.accountId)return setError("اختر البنك أو الخزينة التي استلمت المبلغ.");
    const commandId=returnForm.commandId||globalThis.crypto.randomUUID();
    if(!returnForm.commandId)setReturnForm(current=>({...current,commandId}));
    setBusy("return");
    const result=await supabase.rpc("record_employee_cash_custody_return",{
      target_custody:returnForm.custodyId,return_amount:amount,returned_on:returnForm.date,
      cash_bank_account:returnForm.accountId,return_notes:returnForm.notes.trim()||null,command_id:commandId,
    });
    setBusy("");
    if(result.error)return setError(friendlyError(result.error));
    setReturnForm(null);setOk("تم استلام المبلغ المردود وتحديث رصيد العهدة.");
    await load();
  }

  const renderTable=(rows,emptyText)=>rows.length?<div style={{overflowX:"auto"}}><table style={tableStyle}><thead><tr>
    {["العهدة","الموظف","المشروع","المصروف","المردود","المتبقي","الحالة","الإجراءات"].map(h=><th key={h} style={cell}>{h}</th>)}
  </tr></thead><tbody>{rows.map(row=><tr key={row.id}>
    <td style={cell}><strong>{row.custody_number}</strong><div>{row.issued_on}</div><small>{row.cash_bank_account_code} · {row.cash_bank_account_name}</small><div>الأصل {money(row.issued_amount)}</div></td>
    <td style={cell}>{row.employee_name}</td>
    <td style={cell}>{row.project_code?(row.project_code+" · "+row.project_name):"بدون مشروع"}</td>
    <td style={cell}>{money(row.settled_amount)}</td>
    <td style={cell}>{money(row.returned_amount)}</td>
    <td style={{...cell,fontWeight:800}}>{money(row.remaining_amount)}</td>
    <td style={cell}>{statusLabel[row.status]||row.status}</td>
    <td style={cell}>{row.status!=="settled"&&<div style={{display:"flex",gap:6,flexWrap:"wrap"}}><Button tone="ghost" onClick={()=>openSettlement(row)}>تسوية مصروف</Button><Button tone="ghost" onClick={()=>openReturn(row)}>رد نقدية</Button></div>}</td>
  </tr>)}</tbody></table></div>:<p>{emptyText}</p>;

  return <div>
    <h2 style={{marginTop:0}}>العهد النقدية للموظفين</h2>
    <p style={{color:"var(--color-text-muted)"}}>صرف عهدة من بنك/خزينة، ثم تسوية المصروفات أو رد المتبقي مع ربط كل حركة بالمحاسبة والمشروع عند اختياره.</p>
    {error&&<Notice type="error">{error}</Notice>}{ok&&<Notice>{ok}</Notice>}

    <Panel title="صرف عهدة جديدة">
      <div style={grid}>
        <Field label="الموظف"><Select value={issue.employeeId} onChange={e=>setIssue({...issue,employeeId:e.target.value,commandId:""})}><option value="">اختر الموظف</option>{workspace.employees.map(e=><option key={e.id} value={e.id}>{e.full_name}{e.job_title?(" · "+e.job_title):""}</option>)}</Select></Field>
        <Field label="المشروع (اختياري)"><Select value={issue.projectId} onChange={e=>setIssue({...issue,projectId:e.target.value,commandId:""})}><option value="">بدون مشروع</option>{workspace.projects.map(p=><option key={p.id} value={p.id}>{p.project_code} · {p.project_name}</option>)}</Select></Field>
        <Field label="مبلغ العهدة"><Input type="number" min="0.01" step="0.01" value={issue.amount} onChange={e=>setIssue({...issue,amount:e.target.value,commandId:""})}/></Field>
        <Field label="حساب الصرف"><Select value={issue.accountId} onChange={e=>setIssue({...issue,accountId:e.target.value,commandId:""})}><option value="">اختر البنك أو الخزينة</option>{workspace.cash_bank_accounts.map(a=><option key={a.id} value={a.id}>{a.account_code} · {a.name_ar||a.name_en}</option>)}</Select></Field>
        <Field label="التاريخ"><Input type="date" value={issue.date} onChange={e=>setIssue({...issue,date:e.target.value,commandId:""})}/></Field>
        <Field label="ملاحظات"><Input value={issue.notes} onChange={e=>setIssue({...issue,notes:e.target.value,commandId:""})}/></Field>
        <Button disabled={busy==="issue"} onClick={submitIssue}>{busy==="issue"?"جارِ الصرف...":"صرف العهدة"}</Button>
      </div>
    </Panel>

    {settlement&&<Panel title={"تسوية مصروف — "+settlement.custodyNumber+" — متبقي "+money(settlement.remaining)}>
      <div style={grid}>
        <Field label="المبلغ المصروف"><Input type="number" min="0.01" step="0.01" max={settlement.remaining} value={settlement.amount} onChange={e=>setSettlement({...settlement,amount:e.target.value,commandId:""})}/></Field>
        <Field label="بند المصروف"><Input value={settlement.category} onChange={e=>setSettlement({...settlement,category:e.target.value,commandId:""})}/></Field>
        <Field label="التاريخ"><Input type="date" value={settlement.date} onChange={e=>setSettlement({...settlement,date:e.target.value,commandId:""})}/></Field>
        <Field label="ملاحظات"><Input value={settlement.notes} onChange={e=>setSettlement({...settlement,notes:e.target.value,commandId:""})}/></Field>
        <div style={{display:"flex",gap:6}}><Button disabled={busy==="settlement"} onClick={submitSettlement}>اعتماد التسوية</Button><Button tone="ghost" onClick={()=>setSettlement(null)}>إلغاء</Button></div>
      </div>
    </Panel>}

    {returnForm&&<Panel title={"رد نقدية — "+returnForm.custodyNumber+" — متبقي "+money(returnForm.remaining)}>
      <div style={grid}>
        <Field label="المبلغ المردود"><Input type="number" min="0.01" step="0.01" max={returnForm.remaining} value={returnForm.amount} onChange={e=>setReturnForm({...returnForm,amount:e.target.value,commandId:""})}/></Field>
        <Field label="حساب الاستلام"><Select value={returnForm.accountId} onChange={e=>setReturnForm({...returnForm,accountId:e.target.value,commandId:""})}><option value="">اختر البنك أو الخزينة</option>{workspace.cash_bank_accounts.map(a=><option key={a.id} value={a.id}>{a.account_code} · {a.name_ar||a.name_en}</option>)}</Select></Field>
        <Field label="التاريخ"><Input type="date" value={returnForm.date} onChange={e=>setReturnForm({...returnForm,date:e.target.value,commandId:""})}/></Field>
        <Field label="ملاحظات"><Input value={returnForm.notes} onChange={e=>setReturnForm({...returnForm,notes:e.target.value,commandId:""})}/></Field>
        <div style={{display:"flex",gap:6}}><Button disabled={busy==="return"} onClick={submitReturn}>تسجيل الرد</Button><Button tone="ghost" onClick={()=>setReturnForm(null)}>إلغاء</Button></div>
      </div>
    </Panel>}

    <Panel title={"العهد المفتوحة ("+openCustodies.length+")"}>{loading?<p>جارِ التحميل...</p>:renderTable(openCustodies,"لا توجد عهد نقدية مفتوحة.")}</Panel>
    <Panel title={"العهد المقفلة ("+closedCustodies.length+")"}>{renderTable(closedCustodies,"لا توجد عهد مقفلة حتى الآن.")}</Panel>
  </div>;
}
