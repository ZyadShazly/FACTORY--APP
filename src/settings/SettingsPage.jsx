import React, { useEffect, useState } from "react";
import { AlertCircle, CheckCircle2, ShieldCheck, Wrench } from "lucide-react";
import { supabase } from "../supabaseClient";
import { configureCurrency, userFacingError } from "../userExperience";

const DEFAULT_CURRENCY = { currency_code: "EGP", currency_symbol: "ج.م", currency_locale: "ar-EG", decimal_places: 2 };

export function SettingsPage({ currentProfile, onRepaired }) {
  const [userId, setUserId] = useState("");
  const [fullName, setFullName] = useState("");
  const [role, setRole] = useState("production");
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState(null);
  const [currency, setCurrency] = useState(DEFAULT_CURRENCY);

  useEffect(() => {
    let active = true;
    supabase.rpc("get_system_settings").then(({ data, error }) => {
      if (!active) return;
      if (error) return setFeedback({ type: "error", message: userFacingError(error, "تعذر تحميل إعدادات العملة.") });
      if (data) { setCurrency(data); configureCurrency(data); }
    });
    return () => { active = false; };
  }, []);

  async function repairAccount(event) {
    event.preventDefault();
    setFeedback(null);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId.trim())) {
      setFeedback({ type: "error", message: "أدخل معرّف مستخدم UUID صحيحًا كما يظهر للمستخدم في شاشة فشل الإعداد." });
      return;
    }
    setBusy(true);
    const mutationResult = await supabase.rpc("admin_repair_missing_profile", {
      target_user_id: userId.trim(), target_full_name: fullName.trim() || null, target_role: role,
    });
    if (mutationResult.error) {
      console.error("[AccountRecovery] repair failed", mutationResult.error);
      setFeedback({ type: "error", message: userFacingError(mutationResult.error, "تعذر إصلاح الحساب.") });
    } else {
      await onRepaired?.();
      setFeedback({ type: "success", message: "تم إنشاء ملف الحساب الآمن. يمكن للمستخدم الضغط على إعادة المحاولة الآن." });
      setUserId(""); setFullName(""); setRole("production");
    }
    setBusy(false);
  }

  async function saveCurrency(event) {
    event.preventDefault();
    setBusy(true); setFeedback(null);
    const result = await supabase.rpc("save_system_settings", { payload: currency });
    if (result.error) setFeedback({ type: "error", message: userFacingError(result.error, "تعذر حفظ إعدادات العملة.") });
    else {
      setCurrency(result.data || currency);
      configureCurrency(result.data || currency);
      setFeedback({ type: "success", message: "تم حفظ العملة العامة وتطبيقها على شاشات النظام." });
    }
    setBusy(false);
  }

  return <div className="settings-page">
    <section className="page-header"><div className="page-header-copy"><div className="page-eyebrow"><ShieldCheck size={15}/><span>الإدارة</span></div><h2>الإعدادات</h2><p>أدوات النظام الإدارية الآمنة والإعدادات العامة.</p></div></section>
    {feedback && <div className={`settings-feedback ${feedback.type}`}>{feedback.type === "error" ? <AlertCircle size={17}/> : <CheckCircle2 size={17}/>}<span>{feedback.message}</span></div>}
    <section className="settings-grid">
      <article className="settings-card"><div className="settings-card-title"><Wrench size={20}/><div><h3>العملة العامة</h3><p>تستخدم في كل المبالغ والتقارير الجديدة داخل النظام.</p></div></div>
        <form onSubmit={saveCurrency} className="recovery-form">
          <label>كود العملة<input required maxLength="3" dir="ltr" value={currency.currency_code || ""} onChange={(e) => setCurrency({ ...currency, currency_code: e.target.value.toUpperCase() })}/></label>
          <label>رمز العملة<input required value={currency.currency_symbol || ""} onChange={(e) => setCurrency({ ...currency, currency_symbol: e.target.value })}/></label>
          <label>التنسيق المحلي<input required dir="ltr" value={currency.currency_locale || ""} onChange={(e) => setCurrency({ ...currency, currency_locale: e.target.value })}/></label>
          <label>المنازل العشرية<select value={currency.decimal_places ?? 2} onChange={(e) => setCurrency({ ...currency, decimal_places: Number(e.target.value) })}><option value="0">0</option><option value="2">2</option><option value="3">3</option></select></label>
          <button type="submit" disabled={busy}>{busy ? "جارِ الحفظ..." : "حفظ العملة"}</button>
        </form>
      </article>
      <article className="settings-card"><div className="settings-card-title"><Wrench size={20}/><div><h3>استرداد حساب ناقص</h3><p>ينشئ Profile مفقودًا لمستخدم Auth موجود، من خلال مسار محمي ومسجل في Audit Log.</p></div></div>
        <form onSubmit={repairAccount} className="recovery-form">
          <label>معرّف المستخدم<input value={userId} onChange={(event) => setUserId(event.target.value)} placeholder="00000000-0000-0000-0000-000000000000" dir="ltr"/></label>
          <label>الاسم الكامل (اختياري)<input value={fullName} onChange={(event) => setFullName(event.target.value)} placeholder="اسم الموظف"/></label>
          <label>الدور الآمن<select value={role} onChange={(event) => setRole(event.target.value)}><option value="production">موظف إنتاج</option><option value="accountant">محاسب</option></select></label>
          <small>لا يمكن لهذا المسار إنشاء Owner أو Manager. يمكن للـOwner ترقية الحساب لاحقًا من شاشة الفريق.</small>
          <button type="submit" disabled={busy}>{busy ? "جارِ الإصلاح..." : "إصلاح الحساب"}</button>
        </form>
      </article>
      <article className="settings-card"><div className="settings-card-title"><ShieldCheck size={20}/><div><h3>حالة الإدارة</h3><p>هوية المنفّذ الحالية وآلية الحماية.</p></div></div><dl><div><dt>الدور</dt><dd>{currentProfile.role}</dd></div><div><dt>حماية RLS</dt><dd>مفعّلة</dd></div><div><dt>Audit Log</dt><dd>إلزامي</dd></div></dl></article>
    </section>
  </div>;
}
