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

  source = replaceRequired(
    source,
    'import { EmployeesTab, PayrollTab } from "./v22/payroll";',
    'import { EmployeesTab } from "./v22/payroll";\nimport { PayrollReviewTab as PayrollTab } from "./v22/PayrollReviewTab";',
    "payroll review module route"
  );

  if (!source.includes("function authErrorMessage(error)")) {
    source = replaceRequired(
      source,
      "/* ----------------------------- شاشة الدخول والتسجيل ----------------------------- */\nfunction AuthGate",
      `/* ----------------------------- شاشة الدخول والتسجيل ----------------------------- */
function authErrorMessage(error) {
  const message = String(error?.message || error || "").toLowerCase();
  if (message.includes("invalid login credentials")) return "بيانات الدخول غير صحيحة. راجع الإيميل وكلمة السر.";
  if (message.includes("email not confirmed")) return "لازم تأكد الإيميل الأول، وبعدها سجّل دخول.";
  if (message.includes("user already registered")) return "الحساب موجود بالفعل. استخدم تسجيل الدخول.";
  if (message.includes("password") && message.includes("least")) return "كلمة السر أقصر من الحد المطلوب.";
  if (message.includes("failed to fetch") || message.includes("network") || message.includes("timeout")) return "تعذر الاتصال بالخادم. راجع الإنترنت وحاول مرة أخرى.";
  return error?.message || "تعذر إتمام العملية. حاول مرة أخرى.";
}

function AuthGate`,
      "auth error mapper"
    );
  }

  const submitPattern = /  async function submit\(\) \{[\s\S]*?\n  \}\n\n  return \(/;
  const replacement = `  async function submit() {
    setErr(""); setInfo("");
    if (!email.trim() || !password) return setErr("اكتب الإيميل وكلمة السر");
    setBusy(true);
    try {
      if (mode === "login") {
        const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (error) setErr(authErrorMessage(error));
      } else {
        if (!fullName.trim()) return setErr("اكتب اسمك");
        const { data: signData, error } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: { data: { full_name: fullName.trim(), role } },
        });
        if (error) return setErr(authErrorMessage(error));
        if (signData?.session) {
          const profileResult = await supabase.rpc("complete_my_profile");
          if (profileResult.error) setErr(authErrorMessage(profileResult.error));
        } else {
          setInfo("تم إنشاء الحساب. افتح الإيميل وأكّد الحساب ثم سجّل دخول.");
        }
      }
    } catch (error) {
      setErr(authErrorMessage(error));
    } finally {
      setBusy(false);
    }
  }

  return (`;
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

  const oldBlock = `      if (!fetchResult.data) {
        console.error("[Bootstrap] authenticated user has no profile", { userId });
        setProfile(null);
        setStatus("missing-profile");
        setError("تم تسجيل الدخول، لكن ملف الحساب الإداري غير موجود.");
        return fetchResult;
      }`;
  const newBlock = `      if (!fetchResult.data) {
        const recoveryResult = await withTimeout(
          supabase.rpc("complete_my_profile"),
          undefined,
          "استغرق استكمال ملف الحساب وقتًا أطول من المتوقع"
        );
        if (!recoveryResult.error && recoveryResult.data) {
          fetchResult = { data: recoveryResult.data, error: null };
        } else {
          console.error("[Bootstrap] authenticated user has no profile", { userId, recoveryError: recoveryResult.error });
          setProfile(null);
          setStatus("missing-profile");
          setError("تم تسجيل الدخول، لكن تعذر استكمال ملف الحساب. تواصل مع مدير النظام.");
          return recoveryResult;
        }
      }`;
  source = replaceRequired(source, oldBlock, newBlock, "missing profile self recovery");
  write(path, source);
}

function patchAssets() {
  const path = "src/assets/AssetsPage.jsx";
  let source = read(path);
  source = replaceRequired(
    source,
    'permissions.assets_return&&a.status==="issued"',
    'permissions.assets_return&&["issued","partially_returned"].includes(a.status)',
    "partial return action"
  );
  write(path, source);
}

function patchPayroll() {
  const path = "src/v22/payroll.jsx";
  let source = read(path);

  if (!source.includes('employee_dependency_summary')) {
    source = replaceRequired(
      source,
      "async function remove(id) { if(!window.confirm(\"حذف سجل الموظف؟\")) return; setError(\"\"); setSuccess(\"\"); const mutationResult=await supabase.from(\"employees\").delete().eq(\"id\",id); const result=await syncMutation({scope:\"employees:delete\",mutationResult,refetch:()=>refresh(\"employees\")}); if(result.error)return setError(result.error.message); setSuccess(\"تم حذف سجل الموظف بنجاح\"); }",
      "async function remove(id) { if(!window.confirm(\"إيقاف الموظف؟ سيظل تاريخه والعهد والرواتب محفوظة.\")) return; setError(\"\"); setSuccess(\"\"); const mutationResult=await supabase.from(\"employees\").update({status:\"suspended\"}).eq(\"id\",id); const result=await syncMutation({scope:\"employees:suspend\",mutationResult,refetch:()=>refresh(\"employees\")}); if(result.error)return setError(result.error.message); setSuccess(\"تم إيقاف الموظف مع الحفاظ على كل السجلات المرتبطة.\"); }",
      "employee soft delete"
    );
  }

  if (!source.includes('row.status !== "draft"')) {
    const modernRemove = 'async function remove(row) { if (!window.confirm("حذف مسير الراتب؟")) return;';
    const guardedRemove = 'async function remove(row) { if (row.status !== "draft") return setError("لا يمكن حذف راتب معتمد أو مدفوع. استخدم مسار العكس أو التصحيح."); if (!window.confirm("حذف مسودة الراتب؟")) return;';
    if (source.includes(modernRemove)) source = source.replace(modernRemove, guardedRemove);
    else source = replaceRequired(
      source,
      "async function remove(row){if(!window.confirm(\"حذف مسير الراتب؟\"))return;setError(\"\");setSuccess(\"\");const mutationResult=await supabase.from(\"payroll\").delete().eq(\"id\",row.id);",
      "async function remove(row){if(row.status!==\"draft\")return setError(\"لا يمكن حذف راتب معتمد أو مدفوع. استخدم مسار العكس أو التصحيح.\");if(!window.confirm(\"حذف مسودة الراتب؟\"))return;setError(\"\");setSuccess(\"\");const mutationResult=await supabase.from(\"payroll\").delete().eq(\"id\",row.id);",
      "final payroll delete guard"
    );
  }

  if (!source.includes('isAdministrativeRole(profile.role) && p.status === "draft"')) {
    const modernButton = 'isAdministrativeRole(profile.role) && <button className="v22-icon-button danger" onClick={() => remove(p)}>';
    const guardedButton = 'isAdministrativeRole(profile.role) && p.status === "draft" && <button className="v22-icon-button danger" onClick={() => remove(p)}>';
    if (source.includes(modernButton)) source = source.replace(modernButton, guardedButton);
    else source = replaceRequired(
      source,
      "{isAdministrativeRole(profile.role)&&<button className=\"v22-icon-button danger\" onClick={()=>remove(p)}><Trash2 size={15}/></button>}",
      "{isAdministrativeRole(profile.role)&&p.status===\"draft\"&&<button className=\"v22-icon-button danger\" onClick={()=>remove(p)}><Trash2 size={15}/></button>}",
      "draft payroll delete button"
    );
  }

  write(path, source);
}

patchApp();
patchBootstrap();
patchAssets();
patchPayroll();
console.log("Operational bug closure applied.");
