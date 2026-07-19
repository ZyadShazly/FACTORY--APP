export const SYSTEM_ROLES = Object.freeze({
  owner: { label: "مالك النظام", desc: "صلاحيات النظام كاملة تلقائيًا مع حماية الحسابات الإدارية." },
  manager: { label: "مدير النظام", desc: "تحكم تشغيلي كامل وإدارة المحاسبين وموظفي الإنتاج فقط." },
  accountant: { label: "محاسب", desc: "صلاحيات مالية وتشغيلية قابلة للتخصيص." },
  production: { label: "موظف إنتاج", desc: "وصول تشغيلي آمن دون البيانات المالية أو الإدارية." },
});

export const PROTECTED_ROLES = Object.freeze(["owner", "manager"]);
export const SELF_SIGNUP_ROLES = Object.freeze(["accountant", "production"]);
export const PRODUCTION_ALLOWED_PAGES = Object.freeze(["projects", "projectFiles", "inventory", "materials", "products", "production", "assets"]);

export function isAdministrativeRole(role) {
  return role === "owner" || role === "manager";
}

export function isOwner(role) {
  return role === "owner";
}

export function identityProtectionReason(actor, target) {
  if (!actor || !target) return "تعذر التحقق من هوية المستخدم.";
  if (actor.id === target.id) return "لا يمكن تعديل دورك أو صلاحياتك أو حالة حسابك بنفسك.";
  if (actor.role === "manager" && isAdministrativeRole(target.role)) return "لا يمكن لمدير النظام إدارة مدير نظام آخر.";
  if (!isAdministrativeRole(actor.role)) return "إدارة الهويات متاحة لمالك النظام ومدير النظام فقط.";
  return "";
}

export function canAssignRole(actorRole, role) {
  if (actorRole === "owner") return Object.hasOwn(SYSTEM_ROLES, role);
  if (actorRole === "manager") return SELF_SIGNUP_ROLES.includes(role);
  return false;
}

export function canAdministerTarget(actor, target) {
  return identityProtectionReason(actor, target) === "";
}
