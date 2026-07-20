import fs from "node:fs";

function read(path) {
  return fs.readFileSync(path, "utf8");
}

function write(path, content) {
  fs.writeFileSync(path, content);
}

function replaceRequired(content, search, replacement, label) {
  if (content.includes(replacement)) return content;
  if (!content.includes(search)) throw new Error(`Missing expected source for ${label}`);
  return content.replace(search, replacement);
}

function patchApp() {
  const path = "src/App.jsx";
  let source = read(path);

  if (!source.includes("function authErrorMessage(error)")) {
    source = replaceRequired(
      source,
      "/* ----------------------------- شاشة الدخول والتسجيل ----------------------------- */\nfunction AuthGate",
      `/* ----------------------------- شاشة الدخول والتسجيل ----------------------------- */\nfunction authErrorMessage(error) {\n  const message = String(error?.message || error || \"\").toLowerCase();\n  if (message.includes(\"invalid login credentials\")) return \"بيانات الدخول غير صحيحة. راجع الإيميل وكلمة السر.\";\n  if (message.includes(\"email not confirmed\")) return \"لازم تأكد الإيميل الأول، وبعدها سجّل دخول.\";\n  if (message.includes(\"user already registered\")) return \"الحساب موجود بالفعل. استخدم تسجيل الدخول.\";\n  if (message.includes(\"password\") && message.includes(\"least\")) return \"كلمة السر أقصر من الحد المطلوب.\";\n  if (message.includes(\"failed to fetch\") || message.includes(\"network\") || message.includes(\"timeout\")) return \"تعذر الاتصال بالخادم. راجع الإنترنت وحاول مرة أخرى.\";\n  return error?.message || \"تعذر إتمام العملية. حاول مرة أخرى.\";\n}\n\nfunction AuthGate`,
      "auth error mapper"
    );
  }

  const submitPattern = /  async function submit\(\) \{[\s\S]*?\n  \}\n\n  return \(/;
  const replacement = `  async function submit() {\n    setErr(\"\"); setInfo(\"\");\n    if (!email.trim() || !password) return setErr(\"اكتب الإيميل وكلمة السر\");\n    setBusy(true);\n    try {\n      if (mode === \"login\") {\n        const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });\n        if (error) setErr(authErrorMessage(error));\n      } else {\n        if (!fullName.trim()) return setErr(\"اكتب اسمك\");\n        const { data: signData, error } = await supabase.auth.signUp({\n          email: email.trim(),\n          password,\n          options: { data: { full_name: fullName.trim(), role } },\n        });\n        if (error) return setErr(authErrorMessage(error));\n        if (signData?.session) {\n          const profileResult = await supabase.rpc(\"complete_my_profile\");\n          if (profileResult.error) setErr(authErrorMessage(profileResult.error));\n        } else {\n          setInfo(\"تم إنشاء الحساب. افتح الإيميل وأكّد الحساب ثم سجّل دخول.\");\n        }\n      }\n    } catch (error) {\n      setErr(authErrorMessage(error));\n    } finally {\n      setBusy(false);\n    }\n  }\n\n  return (`;
  if (!source.includes("options: { data: { full_name: fullName.trim(), role } }")) {
    if (!submitPattern.test(source)) throw new Error("Missing AuthGate submit function");
    source = source.replace(submitPattern, replacement);
  }

  write(path, source);
}

function patchBootstrap() {
  const path = "src/auth/useProfileBootstrap.js";
  let source = read(path);
  source = replaceRequired(
    source,
    "      const fetchResult = await withTimeout(",
    "      let fetchResult = await withTimeout(",
    "mutable bootstrap result"
  );

  const oldBlock = `      if (!fetchResult.data) {\n        console.error(\"[Bootstrap] authenticated user has no profile\", { userId });\n        setProfile(null);\n        setStatus(\"missing-profile\");\n        setError(\"تم تسجيل الدخول، لكن ملف الحساب الإداري غير موجود.\");\n        return fetchResult;\n      }`;
  const newBlock = `      if (!fetchResult.data) {\n        const recoveryResult = await withTimeout(\n          supabase.rpc(\"complete_my_profile\"),\n          undefined,\n          \"استغرق استكمال ملف الحساب وقتًا أطول من المتوقع\"\n        );\n        if (!recoveryResult.error && recoveryResult.data) {\n          fetchResult = { data: recoveryResult.data, error: null };\n        } else {\n          console.error(\"[Bootstrap] authenticated user has no profile\", { userId, recoveryError: recoveryResult.error });\n          setProfile(null);\n          setStatus(\"missing-profile\");\n          setError(\"تم تسجيل الدخول، لكن تعذر استكمال ملف الحساب. تواصل مع مدير النظام.\");\n          return recoveryResult;\n        }\n      }`;
  source = replaceRequired(source, oldBlock, newBlock, "missing profile self recovery");
  write(path, source);
}

function patchAssets() {
  const path = "src/assets/AssetsPage.jsx";
  let source = read(path);
  source = replaceRequired(
    source,
    "async function issue(e){e.preventDefault();setBusy(true);try{const linkedProfile=linkedProfileForEmployee(data.profiles,issueForm.receiver_employee_id);",
    "async function issue(e){e.preventDefault();setBusy(true);try{const selectedEmployee=(data.employees||[]).find(employee=>employee.id===issueForm.receiver_employee_id);const linkedProfile=linkedProfileForEmployee(data.profiles,issueForm.receiver_employee_id);",
    "asset receiver snapshot"
  );
  source = replaceRequired(
    source,
    "phone:ass?.receiver_phone_snapshot",
    "phone:selectedEmployee?.phone||ass?.receiver_phone_snapshot",
    "asset share phone"
  );
  source = replaceRequired(
    source,
    "permissions.assets_return&&a.status===\"issued\"",
    "permissions.assets_return&&[\"issued\",\"partially_returned\"].includes(a.status)",
    "partial return action"
  );
  write(path, source);
}

function patchPayroll() {
  const path = "src/v22/payroll.jsx";
  let source = read(path);
  source = replaceRequired(
    source,
    "async function remove(id) { if(!window.confirm(\"حذف سجل الموظف؟\")) return; setError(\"\"); setSuccess(\"\"); const mutationResult=await supabase.from(\"employees\").delete().eq(\"id\",id); const result=await syncMutation({scope:\"employees:delete\",mutationResult,refetch:()=>refresh(\"employees\")}); if(result.error)return setError(result.error.message); setSuccess(\"تم حذف سجل الموظف بنجاح\"); }",
    "async function remove(id) { if(!window.confirm(\"إيقاف الموظف؟ سيظل تاريخه والعهد والرواتب محفوظة.\")) return; setError(\"\"); setSuccess(\"\"); const mutationResult=await supabase.from(\"employees\").update({status:\"suspended\"}).eq(\"id\",id); const result=await syncMutation({scope:\"employees:suspend\",mutationResult,refetch:()=>refresh(\"employees\")}); if(result.error)return setError(result.error.message); setSuccess(\"تم إيقاف الموظف مع الحفاظ على كل السجلات المرتبطة.\"); }",
    "employee soft delete"
  );
  source = replaceRequired(
    source,
    "async function remove(row){if(!window.confirm(\"حذف مسير الراتب؟\"))return;setError(\"\");setSuccess(\"\");const mutationResult=await supabase.from(\"payroll\").delete().eq(\"id\",row.id);",
    "async function remove(row){if(row.status!==\"draft\")return setError(\"لا يمكن حذف راتب معتمد أو مدفوع. استخدم مسار العكس أو التصحيح.\");if(!window.confirm(\"حذف مسودة الراتب؟\"))return;setError(\"\");setSuccess(\"\");const mutationResult=await supabase.from(\"payroll\").delete().eq(\"id\",row.id);",
    "final payroll delete guard"
  );
  source = replaceRequired(
    source,
    "{isAdministrativeRole(profile.role)&&<button className=\"v22-icon-button danger\" onClick={()=>remove(p)}><Trash2 size={15}/></button>}",
    "{isAdministrativeRole(profile.role)&&p.status===\"draft\"&&<button className=\"v22-icon-button danger\" onClick={()=>remove(p)}><Trash2 size={15}/></button>}",
    "draft payroll delete button"
  );
  write(path, source);
}

patchApp();
patchBootstrap();
patchAssets();
patchPayroll();
console.log("Operational bug closure applied.");
