import { downloadExcelWorkbook } from "../reporting/excelWorkbook";
import { compactAccountCode } from "./accountCodes";

const num=(value)=>Number(value||0);
const stamp=()=>new Date().toISOString().slice(0,10);

function downloadWorkbook(filename,reportTitle,filters,sheets){
  downloadExcelWorkbook({
    filename:`${filename}-${stamp()}.xml`,
    meta:{
      company:"NextEP ERP",
      reportTitle,
      generatedBy:"مستخدم النظام",
      generatedAt:new Date().toISOString(),
      filters,
    },
    sheets,
  });
}

export function exportChartOfAccounts(accounts=[]){
  const byId=new Map(accounts.map((row)=>[row.id,row]));
  const rows=accounts.map((row)=>({
    ...row,
    compact_code:compactAccountCode(row.account_code),
    parent_code:compactAccountCode(byId.get(row.parent_id)?.account_code),
    parent_name:byId.get(row.parent_id)?.name_ar||"",
    posting_label:row.is_posting?"حركة":"تجميعي",
    active_label:row.is_active?"نشط":"معطل",
    contra_label:row.is_contra?"نعم":"لا",
  }));
  downloadWorkbook("chart-of-accounts","شجرة الحسابات",{"النطاق":"كل الحسابات"},[{
    name:"شجرة الحسابات",
    columns:[
      {label:"الكود",key:"compact_code",width:90},
      {label:"الاسم بالعربي",key:"name_ar",width:170},
      {label:"الاسم بالإنجليزي",key:"name_en",width:170},
      {label:"كود الأب",key:"parent_code",width:90},
      {label:"الحساب الأب",key:"parent_name",width:160},
      {label:"نوع الحساب",key:"account_type",width:100},
      {label:"طبيعة الحساب",key:"posting_label",width:90},
      {label:"الحالة",key:"active_label",width:80,type:"status"},
      {label:"Contra",key:"contra_label",width:70},
      {label:"الوصف",key:"description",width:220},
    ],
    rows,
  }]);
}

export function exportJournalRegister(journals=[],accounts=[],filters={}){
  const byId=new Map(accounts.map((row)=>[row.id,row]));
  const headerRows=journals.map((row)=>({
    entry_number:row.entry_number,
    entry_date:row.entry_date,
    status:row.status,
    origin:row.entry_origin,
    reference:row.reference,
    description:row.description,
    total_debit:num(row.total_debit),
    total_credit:num(row.total_credit),
    source_module:row.source_module,
    source_record_id:row.source_record_id,
  }));
  const lineRows=journals.flatMap((row)=>(row.lines||[]).map((line)=>({
    entry_number:row.entry_number,
    entry_date:row.entry_date,
    status:row.status,
    account_code:compactAccountCode(byId.get(line.account_id)?.account_code),
    account_name:byId.get(line.account_id)?.name_ar||"حساب",
    debit:num(line.debit),
    credit:num(line.credit),
    description:line.description||row.description||"",
    reference:line.reference||row.reference||"",
  })));
  downloadWorkbook("journal-register","سجل القيود اليومية",{
    "من":filters.from||"الكل",
    "إلى":filters.to||"الكل",
  },[
    {
      name:"القيود",
      columns:[
        {label:"رقم القيد",key:"entry_number",width:110},
        {label:"التاريخ",key:"entry_date",type:"date",width:90},
        {label:"الحالة",key:"status",type:"status",width:80},
        {label:"النوع",key:"origin",width:80},
        {label:"المرجع",key:"reference",width:130},
        {label:"البيان",key:"description",width:220},
        {label:"إجمالي مدين",key:"total_debit",type:"currency",width:100},
        {label:"إجمالي دائن",key:"total_credit",type:"currency",width:100},
        {label:"المصدر",key:"source_module",width:90},
        {label:"معرف المصدر",key:"source_record_id",width:180},
      ],
      rows:headerRows,
    },
    {
      name:"أطراف القيود",
      columns:[
        {label:"رقم القيد",key:"entry_number",width:110},
        {label:"التاريخ",key:"entry_date",type:"date",width:90},
        {label:"الحالة",key:"status",type:"status",width:80},
        {label:"كود الحساب",key:"account_code",width:90},
        {label:"الحساب",key:"account_name",width:170},
        {label:"مدين",key:"debit",type:"currency",width:100},
        {label:"دائن",key:"credit",type:"currency",width:100},
        {label:"بيان السطر",key:"description",width:220},
        {label:"المرجع",key:"reference",width:150},
      ],
      rows:lineRows,
    },
  ]);
}

function esc(value){
  return String(value??"")
    .replaceAll("&","&amp;")
    .replaceAll("<","&lt;")
    .replaceAll(">","&gt;")
    .replaceAll('"',"&quot;")
    .replaceAll("'","&#39;");
}

export function printJournal(row,accounts=[]){
  const byId=new Map(accounts.map((account)=>[account.id,account]));
  const lines=(row.lines||[]).map((line)=>{
    const account=byId.get(line.account_id)||{};
    return `<tr>
      <td>${esc(compactAccountCode(account.account_code)||"—")}</td>
      <td>${esc(account.name_ar||"حساب")}</td>
      <td>${num(line.debit).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2})}</td>
      <td>${num(line.credit).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2})}</td>
      <td>${esc(line.description||"")}</td>
    </tr>`;
  }).join("");
  const popup=window.open("","_blank","noopener,noreferrer,width=1000,height=800");
  if(!popup)return false;
  popup.document.write(`<!doctype html><html dir="rtl" lang="ar"><head><meta charset="utf-8"><title>${esc(row.entry_number||"قيد يومية")}</title>
  <style>
    body{font-family:Arial,sans-serif;margin:32px;color:#111}
    h1{margin:0 0 6px;font-size:24px} .meta{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;margin:18px 0}
    .meta div{border:1px solid #ddd;padding:8px}.meta span{display:block;color:#666;font-size:12px;margin-bottom:3px}
    table{width:100%;border-collapse:collapse;margin-top:16px}th,td{border:1px solid #bbb;padding:8px;text-align:right}
    th{background:#eee}.totals{display:flex;gap:26px;justify-content:flex-end;margin-top:12px;font-weight:bold}
    .sign{display:grid;grid-template-columns:repeat(3,1fr);gap:24px;margin-top:54px;text-align:center}
    .sign div{border-top:1px solid #777;padding-top:8px}
    @media print{body{margin:12mm}@page{size:A4;margin:12mm}}
  </style></head><body>
    <h1>قيد يومية ${esc(row.entry_number||"")}</h1>
    <div class="meta">
      <div><span>التاريخ</span><b>${esc(row.entry_date||"")}</b></div>
      <div><span>الحالة</span><b>${esc(row.status||"")}</b></div>
      <div><span>المرجع</span><b>${esc(row.reference||"—")}</b></div>
      <div><span>النوع</span><b>${esc(row.entry_origin||"")}</b></div>
    </div>
    <p><b>البيان:</b> ${esc(row.description||"")}</p>
    <table><thead><tr><th>الكود</th><th>الحساب</th><th>مدين</th><th>دائن</th><th>البيان</th></tr></thead><tbody>${lines}</tbody></table>
    <div class="totals"><span>إجمالي المدين: ${num(row.total_debit).toFixed(2)}</span><span>إجمالي الدائن: ${num(row.total_credit).toFixed(2)}</span></div>
    <div class="sign"><div>إعداد</div><div>مراجعة</div><div>اعتماد</div></div>
    <script>window.addEventListener("load",()=>{window.print()})<\/script>
  </body></html>`);
  popup.document.close();
  return true;
}

function csvEscape(value){
  const text=String(value??"");
  return /[",\n\r]/.test(text)?`"${text.replaceAll('"','""')}"`:text;
}

export function downloadJournalImportTemplate(){
  const headers=["entry_key","entry_date","reference","description","entry_origin","account_code","debit","credit","line_description"];
  const example=[
    ["EXAMPLE-1",stamp(),"REF-001","مثال قيد استيراد","manual","1102","100","0","السطر المدين"],
    ["EXAMPLE-1",stamp(),"REF-001","مثال قيد استيراد","manual","690","0","100","السطر الدائن"],
  ];
  const csv=[headers,...example].map((row)=>row.map(csvEscape).join(",")).join("\r\n");
  const blob=new Blob(["\ufeff",csv],{type:"text/csv;charset=utf-8"});
  const url=URL.createObjectURL(blob);
  const anchor=document.createElement("a");
  anchor.href=url;
  anchor.download="journal-import-template.csv";
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}

function detectDelimiter(text){
  const first=String(text||"").replace(/^\ufeff/,"").split(/\r?\n/).find((line)=>line.trim())||"";
  const candidates=[",",";","\t"];
  return candidates.sort((a,b)=>(first.split(b).length-first.split(a).length))[0];
}

function parseDelimited(text,delimiter){
  const rows=[];
  let row=[],cell="",quoted=false;
  const source=String(text||"").replace(/^\ufeff/,"");
  for(let i=0;i<source.length;i+=1){
    const ch=source[i];
    if(ch==='"'){
      if(quoted&&source[i+1]==='"'){cell+='"';i+=1}
      else quoted=!quoted;
    }else if(ch===delimiter&&!quoted){
      row.push(cell);cell="";
    }else if((ch==="\n"||ch==="\r")&&!quoted){
      if(ch==="\r"&&source[i+1]==="\n")i+=1;
      row.push(cell);cell="";
      if(row.some((value)=>String(value).trim()!==""))rows.push(row);
      row=[];
    }else cell+=ch;
  }
  row.push(cell);
  if(row.some((value)=>String(value).trim()!==""))rows.push(row);
  return rows;
}

const HEADER_ALIASES={
  entry_key:["entry_key","مفتاح_القيد","رقم_المجموعة"],
  entry_date:["entry_date","تاريخ_القيد","التاريخ"],
  reference:["reference","المرجع"],
  description:["description","بيان_القيد","البيان"],
  entry_origin:["entry_origin","نوع_القيد"],
  account_code:["account_code","كود_الحساب"],
  debit:["debit","مدين"],
  credit:["credit","دائن"],
  line_description:["line_description","بيان_السطر"],
};

function headerIndex(headers,key){
  const normalized=headers.map((value)=>String(value||"").trim().toLowerCase());
  return normalized.findIndex((value)=>HEADER_ALIASES[key].includes(value));
}

export function parseJournalImportCsv(text){
  const delimiter=detectDelimiter(text);
  const table=parseDelimited(text,delimiter);
  if(table.length<2)throw new Error("الملف لا يحتوي بيانات للاستيراد.");
  const headers=table[0];
  const idx=Object.fromEntries(Object.keys(HEADER_ALIASES).map((key)=>[key,headerIndex(headers,key)]));
  for(const required of ["entry_key","entry_date","description","account_code","debit","credit"]){
    if(idx[required]<0)throw new Error(`العمود المطلوب غير موجود: ${required}`);
  }
  const groups=new Map();
  for(const raw of table.slice(1)){
    const get=(key)=>idx[key]>=0?String(raw[idx[key]]??"").trim():"";
    const entryKey=get("entry_key");
    if(!entryKey||entryKey.startsWith("#"))continue;
    const header={
      entry_key:entryKey,
      entry_date:get("entry_date"),
      reference:get("reference")||null,
      description:get("description"),
      entry_origin:get("entry_origin")||"manual",
    };
    if(!groups.has(entryKey))groups.set(entryKey,{...header,lines:[]});
    const entry=groups.get(entryKey);
    if(entry.entry_date!==header.entry_date||entry.description!==header.description||entry.reference!==header.reference||entry.entry_origin!==header.entry_origin){
      throw new Error(`بيانات رأس القيد غير متطابقة داخل المجموعة ${entryKey}.`);
    }
    entry.lines.push({
      account_code:get("account_code"),
      debit:get("debit")||"0",
      credit:get("credit")||"0",
      line_description:get("line_description")||null,
    });
  }
  const entries=[...groups.values()];
  if(!entries.length)throw new Error("لم يتم العثور على قيود قابلة للاستيراد.");
  return entries;
}

export function exportLedgerReport(report,account,filters){
  const rows=report?.transactions||[];
  downloadWorkbook("account-ledger","كشف حساب",{
    "الحساب":account?`${compactAccountCode(account.account_code)} · ${account.name_ar}`:"—",
    "من":filters.from||"",
    "إلى":filters.to||"",
  },[{
    name:"كشف الحساب",
    summary:[
      {label:"الرصيد الافتتاحي",value:num(report?.opening_balance),type:"currency"},
      {label:"الرصيد الختامي",value:num(report?.closing_balance),type:"currency"},
      {label:"عدد الحركات",value:rows.length,type:"number"},
    ],
    columns:[
      {label:"التاريخ",key:"entry_date",type:"date",width:90},
      {label:"القيد",key:"entry_number",width:110},
      {label:"البيان",width:220,value:(r)=>r.line_description||r.journal_description||""},
      {label:"المرجع",width:140,value:(r)=>r.line_reference||r.journal_reference||""},
      {label:"مدين",key:"debit",type:"currency",width:90},
      {label:"دائن",key:"credit",type:"currency",width:90},
      {label:"الرصيد الجاري",key:"running_balance",type:"currency",width:100},
      {label:"المصدر",key:"source_module",width:100},
      {label:"معرف المصدر",key:"source_record_id",width:180},
    ],
    rows,
  }]);
}

export function exportTrialBalanceReport(report,filters){
  const rows=(report?.rows||[]).map((r)=>({...r,display_code:compactAccountCode(r.account_code)}));
  const totals=report?.totals||{};
  downloadWorkbook("trial-balance","ميزان المراجعة",{"من":filters.from||"","إلى":filters.to||""},[{
    name:"ميزان المراجعة",
    summary:[
      {label:"حركة مدين",value:num(totals.period_debit),type:"currency"},
      {label:"حركة دائن",value:num(totals.period_credit),type:"currency"},
    ],
    columns:[
      {label:"الكود",key:"display_code",width:90},
      {label:"الحساب",key:"name_ar",width:180},
      {label:"افتتاحي مدين",key:"opening_debit",type:"currency",width:100},
      {label:"افتتاحي دائن",key:"opening_credit",type:"currency",width:100},
      {label:"حركة مدين",key:"period_debit",type:"currency",width:100},
      {label:"حركة دائن",key:"period_credit",type:"currency",width:100},
      {label:"ختامي مدين",key:"closing_debit",type:"currency",width:100},
      {label:"ختامي دائن",key:"closing_credit",type:"currency",width:100},
    ],
    rows,
  }]);
}

export function exportBalanceSheetReport(report,date){
  const rows=(report?.rows||[]).map((r)=>({...r,display_code:compactAccountCode(r.account_code)}));
  const s=report?.summary||{};
  downloadWorkbook("balance-sheet","قائمة المركز المالي",{"حتى تاريخ":date||""},[{
    name:"المركز المالي",
    summary:[
      {label:"إجمالي الأصول",value:num(s.total_assets),type:"currency"},
      {label:"إجمالي الالتزامات",value:num(s.total_liabilities),type:"currency"},
      {label:"إجمالي حقوق الملكية",value:num(s.total_equity),type:"currency"},
      {label:"الفرق",value:num(s.difference),type:"currency"},
    ],
    columns:[
      {label:"الكود",key:"display_code",width:90},
      {label:"الحساب",key:"name_ar",width:180},
      {label:"النوع",key:"account_type",width:100},
      {label:"الرصيد",key:"amount",type:"currency",width:110},
      {label:"حركة/تجميعي",width:90,value:(r)=>r.is_posting?"حركة":"تجميعي"},
    ],
    rows,
  }]);
}

export function exportProfitLossReport(report,filters){
  const rows=(report?.rows||[]).map((r)=>({...r,display_code:compactAccountCode(r.account_code)}));
  const s=report?.summary||{};
  downloadWorkbook("profit-loss","قائمة الأرباح والخسائر",{"من":filters.from||"","إلى":filters.to||""},[{
    name:"الأرباح والخسائر",
    summary:[
      {label:"الإيرادات",value:num(s.revenue),type:"currency"},
      {label:"تكلفة المبيعات",value:num(s.cost_of_sales),type:"currency"},
      {label:"مجمل الربح",value:num(s.gross_profit),type:"currency"},
      {label:"المصروفات",value:num(s.expenses),type:"currency"},
      {label:"صافي الربح / الخسارة",value:num(s.profit_loss),type:"currency"},
    ],
    columns:[
      {label:"الكود",key:"display_code",width:90},
      {label:"الحساب",key:"name_ar",width:180},
      {label:"النوع",key:"account_type",width:100},
      {label:"المبلغ",key:"amount",type:"currency",width:110},
      {label:"حركة/تجميعي",width:90,value:(r)=>r.is_posting?"حركة":"تجميعي"},
    ],
    rows,
  }]);
}
