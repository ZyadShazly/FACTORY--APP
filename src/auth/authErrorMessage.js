export function authErrorMessage(error) {
  const message = String(error?.message || error || "").toLowerCase();
  if (message.includes("invalid login credentials")) return "بيانات الدخول غير صحيحة. راجع الإيميل وكلمة السر.";
  if (message.includes("email not confirmed")) return "لازم تأكد الإيميل الأول، وبعدها سجّل دخول.";
  if (message.includes("user already registered")) return "الحساب موجود بالفعل. استخدم تسجيل الدخول.";
  if (message.includes("password") && message.includes("least")) return "كلمة السر أقصر من الحد المطلوب.";
  if (message.includes("failed to fetch") || message.includes("network") || message.includes("timeout")) return "تعذر الاتصال بالخادم. راجع الإنترنت وحاول مرة أخرى.";
  return error?.message || "تعذر إتمام العملية. حاول مرة أخرى.";
}
