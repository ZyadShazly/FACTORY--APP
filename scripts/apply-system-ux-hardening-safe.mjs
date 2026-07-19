import fs from 'node:fs';

function edit(path, rules) {
  let text = fs.readFileSync(path, 'utf8');
  const original = text;
  for (const rule of rules) {
    const next = text.replace(rule.search, rule.replace);
    if (next === text) console.warn(`[ux-patch] skipped ${path}: ${rule.name}`);
    text = next;
  }
  if (text !== original) {
    fs.writeFileSync(path, text);
    console.log(`[ux-patch] updated ${path}`);
  }
}

edit('src/v22/shared.jsx', [
  { name:'UX import', search:'import { AlertCircle, CheckCircle2, Loader2, X } from "lucide-react";', replace:'import { AlertCircle, CheckCircle2, Loader2, X } from "lucide-react";\nimport { formatMoney, userFacingError } from "../userExperience";' },
  { name:'currency formatter', search:/export const money = \(value\) => `\$\{Number\(value \|\| 0\)\.toLocaleString\("ar-EG", \{ minimumFractionDigits: 2, maximumFractionDigits: 2 \}\)\} ج\.م`;/, replace:'export const money = (value) => formatMoney(value);' },
  { name:'friendly error state', search:'return error ? <div className="v22-alert error"><AlertCircle size={17} />{error}</div> : null;', replace:'return error ? <div className="v22-alert error"><AlertCircle size={17} />{userFacingError(error)}</div> : null;' },
]);

edit('src/v22/payroll.jsx', [
  { name:'employee deactivation', search:/async function remove\(id\) \{ if\(!window\.confirm\("حذف سجل الموظف\?"\)\) return;[\s\S]*?setSuccess\("تم حذف سجل الموظف بنجاح"\); \}/, replace:'async function remove(id) { if(!window.confirm("سيتم تعطيل الموظف مع الاحتفاظ بكل سجلاته التاريخية. متابعة؟")) return; setError(""); setSuccess(""); const mutationResult=await supabase.rpc("deactivate_employee",{target_employee:id,reason:"تعطيل من شاشة الموظفين"}); const result=await syncMutation({scope:"employees:deactivate",mutationResult,refetch:()=>refresh("employees")}); if(result.error)return setError(result.error); setSuccess("تم تعطيل الموظف مع الاحتفاظ بالسجل التاريخي"); }' },
]);

edit('src/assets/AssetsPage.jsx', [
  { name:'asset UX imports', search:'import{Button,DataTable,EmptyState,ErrorState,Field,Input,PageTitle,Panel,Select,StatCard,SuccessState,TextArea}from"../v22/shared";', replace:'import{Button,DataTable,EmptyState,ErrorState,Field,Input,PageTitle,Panel,Select,StatCard,SuccessState,TextArea,money}from"../v22/shared";\nimport{confirmationStatusLabel,userFacingError}from"../userExperience";' },
  { name:'friendly asset RPC errors', search:/async function rpc\(name,args\)\{const result=await supabase\.rpc\(name,args\);console\.info\(`\[Assets\] \$\{name\}`,result\);if\(result\.error\)throw result\.error;if\(result\.data\?\.ok===false\)throw new Error\(result\.data\.error\|\|"تعذر تنفيذ العملية"\);return result\.data\}/, replace:'async function rpc(name,args){const result=await supabase.rpc(name,args);console.info(`[Assets] ${name}`,result);if(result.error)throw new Error(userFacingError(result.error));if(result.data?.ok===false)throw new Error(userFacingError(result.data.error));return result.data}' },
  { name:'currency report', search:/`\$\{data\.assets\.reduce\(\(s,a\)=>s\+Number\(a\.purchase_cost\|\|0\),0\)\.toLocaleString\('ar-SA'\)\} ر\.س`/, replace:'money(data.assets.reduce((s,a)=>s+Number(a.purchase_cost||0),0))' },
  { name:'assignment link status', search:'{ASSIGNMENT_STATUS[a.status]}<ConfirmationBadge method={a.confirmation_method}/>', replace:'{ASSIGNMENT_STATUS[a.status]}<ConfirmationBadge method={a.confirmation_method}/><small className="table-sub">الرابط: {confirmationStatusLabel(a)}</small>' },
  { name:'return link status', search:'<td>{r.status}<ConfirmationBadge method={r.confirmation_method}/></td>', replace:'<td>{r.status}<ConfirmationBadge method={r.confirmation_method}/><small className="table-sub">الرابط: {confirmationStatusLabel(r)}</small></td>' },
  { name:'external missing state', search:'if(!id||!secret)return setState({status:"expired"})', replace:'if(!id||!secret)return setState({status:"not_found"})' },
  { name:'explicit external messages', search:'if(["expired","invalid","rate_limited"].includes(state.status))return <ExternalState title="الرابط غير متاح" text={state.status==="rate_limited"?"تم تجاوز عدد المحاولات. حاول لاحقًا.":"انتهت صلاحية الرابط أو تم استخدامه من قبل."}/>;', replace:'const linkMessages={not_found:["الرابط غير صحيح","تعذر العثور على عملية مرتبطة بهذا الرابط."],invalid:["الرابط غير صحيح","رمز التأكيد غير صحيح."],expired:["انتهت صلاحية الرابط","انتهت مدة التأكيد وما زالت العملية معلقة. اطلب رابطًا جديدًا."],rate_limited:["تم إيقاف المحاولات مؤقتًا","تم تجاوز عدد المحاولات. حاول لاحقًا."],already_confirmed:["تم التأكيد مسبقًا","هذه العملية مكتملة بالفعل."],already_used:["تم استخدام الرابط","تم استخدام هذا الرابط من قبل."],cancelled:["تم إلغاء العملية","لا يمكن استخدام رابط تابع لعملية ملغاة."],replaced:["تم استبدال الرابط","استخدم آخر رابط تم إرساله."],pending_without_link:["لا يوجد رابط نشط","العملية معلقة لكن لم يتم إنشاء رابط لها."],not_pending:["تغيرت حالة العملية","حدّث الصفحة لمعرفة الحالة الحالية."]};if(linkMessages[state.status])return <ExternalState title={linkMessages[state.status][0]} text={linkMessages[state.status][1]}/>;' },
]);

edit('src/v22/projects.jsx', [
  { name:'stage filter', search:'&& (!status || project.status === status)', replace:'&& (!status || (project.execution_stage || project.status) === status)' },
  { name:'draft button label', search:'<Button type="submit">حفظ المشروع</Button>', replace:'<Button type="submit">إنشاء مسودة المشروع</Button>' },
  { name:'result count', search:'{projects.length ? <div className="projects-grid">', replace:'<div className="projects-result-count">عدد النتائج: <b>{projects.length}</b></div>{projects.length ? <div className="projects-grid">' },
]);

edit('src/v22/projectWorkspace.jsx', [
  { name:'hide unfinished reports tab', search:'["reports", "التقارير", FileText],\n   ["activity", "سجل النشاط", History],', replace:'["activity", "سجل النشاط", History],' },
  { name:'normalize management wrapper', search:/(?:<details className="workspace-management"><summary>إدارة حالة المشروع والإنجاز<\/summary>)+<div className="workspace-actions-grid">/, replace:'<details className="workspace-management"><summary>إدارة حالة المشروع والإنجاز</summary><div className="workspace-actions-grid">' },
  { name:'add management close', search:/<\/PermissionGuard><\/div>(?!<\/details>)\n       <Panel><h3>آخر النشاط<\/h3>/, replace:'</PermissionGuard></div></details>\n       <Panel><h3>آخر النشاط</h3>' },
]);

console.log('[ux-patch] completed');
