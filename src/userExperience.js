const DEFAULT_CURRENCY = Object.freeze({
  currency_code: "EGP",
  currency_symbol: "ج.م",
  currency_locale: "ar-EG",
  decimal_places: 2,
});

let currency = { ...DEFAULT_CURRENCY };

export function configureCurrency(next = {}) {
  currency = {
    ...DEFAULT_CURRENCY,
    ...Object.fromEntries(Object.entries(next || {}).filter(([, value]) => value !== null && value !== undefined && value !== "")),
  };
  try { localStorage.setItem("nextep.currency", JSON.stringify(currency)); } catch {}
  return currency;
}

export function restoreCurrency() {
  try {
    const saved = JSON.parse(localStorage.getItem("nextep.currency") || "null");
    if (saved) configureCurrency(saved);
  } catch {}
  return currency;
}

restoreCurrency();

export function formatMoney(value, overrides = {}) {
  const settings = { ...currency, ...overrides };
  const amount = Number.isFinite(Number(value)) ? Number(value) : 0;
  const decimals = Math.max(0, Math.min(4, Number(settings.decimal_places ?? 2)));
  return `${amount.toLocaleString(settings.currency_locale || "ar-EG", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })} ${settings.currency_symbol || settings.currency_code || ""}`.trim();
}

const FRIENDLY_BY_CODE = {
  "23503": "لا يمكن حذف هذا السجل لأنه مرتبط ببيانات تاريخية. عطّله أو أرشفه بدلًا من الحذف.",
  "23505": "هذه البيانات مسجلة بالفعل. راجع القيم المكررة ثم حاول مرة أخرى.",
  "23514": "بعض القيم المدخلة غير متوافقة مع قواعد النظام.",
  "42501": "ليس لديك صلاحية لتنفيذ هذا الإجراء.",
  "PGRST116": "السجل المطلوب غير موجود أو لم يعد متاحًا.",
};

export function userFacingError(error, fallback = "تعذر إكمال العملية. راجع البيانات وحاول مرة أخرى.") {
  if (!error) return fallback;
  const code = String(error.code || "");
  if (FRIENDLY_BY_CODE[code]) return FRIENDLY_BY_CODE[code];
  const raw = String(error.message || error || "").trim();
  const lower = raw.toLowerCase();
  if (lower.includes("foreign key") || lower.includes("violates foreign key") || lower.includes("still referenced")) return FRIENDLY_BY_CODE["23503"];
  if (lower.includes("duplicate key") || lower.includes("unique constraint")) return FRIENDLY_BY_CODE["23505"];
  if (lower.includes("permission") || lower.includes("not authorized") || lower.includes("authorization required")) return FRIENDLY_BY_CODE["42501"];
  if (lower.includes("confirmation_token_hash")) return "تعذر إكمال الإرجاع لأن بيانات رابط التأكيد غير متوافقة. أعد المحاولة بعد تحديث الصفحة.";
  if (lower.includes("return quantity exceeds")) return "كمية الإرجاع أكبر من الكمية المتبقية في العهدة.";
  if (lower.includes("assignment is not pending") || lower.includes("return event is not pending")) return "تغيرت حالة العملية بالفعل. حدّث الصفحة لمشاهدة الحالة الحالية.";
  if (/constraint|sql|postgres|relation |column |function |rpc/i.test(raw)) return fallback;
  return raw || fallback;
}

export const confirmationStatusLabel = (row = {}) => {
  if (row.confirmed_at || row.status === "confirmed") return "تم التأكيد";
  if (row.confirmation_invalidated_at) return "تم إلغاء الرابط";
  if (row.confirmation_used_at) return "تم استخدام الرابط";
  if (row.confirmation_expires_at && new Date(row.confirmation_expires_at).getTime() <= Date.now()) return "انتهت صلاحيته";
  if (row.confirmation_opened_at) return "تم فتحه";
  if (row.confirmation_sent_at) return "أُرسل";
  if (row.confirmation_token_hash) return "لم يُرسل";
  return "لا يوجد رابط";
};
