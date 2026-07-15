export const SYSTEM_ROLES = Object.freeze({
  owner: { label: "مالك النظام", desc: "صلاحيات النظام كاملة تلقائيًا مع حماية الحسابات الإدارية." },
  manager: { label: "مدير النظام", desc: "تحكم تشغيلي كامل وإدارة المستخدمين غير المالكين." },
  accountant: { label: "محاسب", desc: "صلاحيات مالية وتشغيلية قابلة للتخصيص." },
  production: { label: "موظف إنتاج", desc: "وصول تشغيلي آمن دون البيانات المالية أو الإدارية." },
});

export const PROTECTED_ROLES = Object.freeze(["owner", "manager"]);
export const SELF_SIGNUP_ROLES = Object.freeze(["accountant", "production"]);
export const PRODUCTION_ALLOWED_PAGES = Object.freeze(["inventory", "materials", "products", "production"]);

export function isAdministrativeRole(role) {
  return role === "owner" || role === "manager";
}

export function isOwner(role) {
  return role === "owner";
}

export function identityProtectionReason(actor, target) {
  if (!actor || !target) return "تعذر التحقق من هوية المستخدم.";
  if (actor.id === target.id) return "لا يمكن تعديل دورك أو صلاحياتك أو حالة حسابك بنفسك.";
  if (actor.role === "manager" && target.role === "owner") return "حساب مالك النظام محمي ولا يمكن لمدير النظام تعديله.";
  if (!isAdministrativeRole(actor.role)) return "إدارة الهويات متاحة لمالك النظام ومدير النظام فقط.";
  return "";
}

export function canAssignRole(actorRole, role) {
  if (role === "owner") return actorRole === "owner";
  return isAdministrativeRole(actorRole);
}
