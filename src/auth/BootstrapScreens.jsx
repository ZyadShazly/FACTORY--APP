import React from "react";
import { AlertCircle, LogOut, RefreshCw } from "lucide-react";

export function BootstrapLoading({ text = "جارِ تحميل النظام..." }) {
  return <main dir="rtl" className="bootstrap-screen" aria-live="polite">
    <span className="bootstrap-spinner" aria-hidden="true" />
    <strong>{text}</strong>
    <p>لن تستمر هذه الشاشة بلا نهاية؛ سنعرض خيار الاسترداد إذا تعذر الاتصال.</p>
  </main>;
}

export function BootstrapFailure({ title = "تعذر تحميل النظام", message, session, missingProfile = false, onRetry, onSignOut }) {
  return <main dir="rtl" className="bootstrap-screen" role="alert">
    <AlertCircle size={38} />
    <strong>{missingProfile ? "فشل إعداد الحساب" : title}</strong>
    <p>{message}</p>
    {missingProfile && <div className="bootstrap-account-reference">
      <span>أرسل هذه البيانات إلى مالك أو مدير النظام لإصلاح الحساب:</span>
      <code>{session?.user?.id}</code>
      <small>{session?.user?.email}</small>
    </div>}
    <div className="bootstrap-actions">
      <button type="button" className="recovery-button primary" onClick={onRetry}><RefreshCw size={16}/>إعادة المحاولة</button>
      <button type="button" className="recovery-button" onClick={onSignOut}><LogOut size={16}/>تسجيل الخروج</button>
    </div>
  </main>;
}
