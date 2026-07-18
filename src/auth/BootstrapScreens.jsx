import React, { useState } from "react";
import { AlertCircle, Check, Copy, LogOut, RefreshCw } from "lucide-react";

function copyWithDocumentFallback(value) {
  const input = document.createElement("textarea");
  input.value = value;
  input.setAttribute("readonly", "");
  input.style.position = "fixed";
  input.style.opacity = "0";
  document.body.appendChild(input);
  input.select();
  const copied = document.execCommand("copy");
  document.body.removeChild(input);
  if (!copied) throw new Error("Clipboard fallback was rejected");
}

export function BootstrapLoading({ text = "جارِ تحميل النظام..." }) {
  return <main dir="rtl" className="bootstrap-screen" aria-live="polite">
    <span className="bootstrap-spinner" aria-hidden="true" />
    <strong>{text}</strong>
    <p>لن تستمر هذه الشاشة بلا نهاية؛ سنعرض خيار الاسترداد إذا تعذر الاتصال.</p>
  </main>;
}

export function BootstrapFailure({ title = "تعذر تحميل النظام", message, session, missingProfile = false, onRetry, onSignOut }) {
  const [copyState, setCopyState] = useState("idle");
  const supportId = session?.user?.id || "";

  async function copySupportId() {
    if (!supportId) return;
    try {
      if (navigator.clipboard?.writeText) {
        try {
          await navigator.clipboard.writeText(supportId);
        } catch {
          copyWithDocumentFallback(supportId);
        }
      } else {
        copyWithDocumentFallback(supportId);
      }
      setCopyState("copied");
    } catch (error) {
      console.error("[Bootstrap] support ID copy failed", error);
      setCopyState("error");
    }
  }

  return <main dir="rtl" className="bootstrap-screen" role="alert">
    <AlertCircle size={38} />
    <strong>{missingProfile ? "فشل إعداد الحساب" : title}</strong>
    <p>{message}</p>
    {missingProfile && <div className="bootstrap-account-reference">
      <span>أرسل بريد الحساب إلى مالك أو مدير النظام لإصلاحه:</span>
      <strong>{session?.user?.email || "البريد الإلكتروني غير متاح"}</strong>
      <button type="button" className="copy-support-id" onClick={copySupportId} disabled={!supportId}>
        {copyState === "copied" ? <Check size={15}/> : <Copy size={15}/>}
        {copyState === "copied" ? "تم نسخ معرف الدعم" : "نسخ معرف الدعم"}
      </button>
      {copyState === "error" && <small className="copy-support-error">تعذر النسخ. أعد المحاولة أو تواصل مع الدعم بالبريد الظاهر.</small>}
    </div>}
    <div className="bootstrap-actions">
      <button type="button" className="recovery-button primary" onClick={onRetry}><RefreshCw size={16}/>إعادة المحاولة</button>
      <button type="button" className="recovery-button" onClick={onSignOut}><LogOut size={16}/>تسجيل الخروج</button>
    </div>
  </main>;
}
