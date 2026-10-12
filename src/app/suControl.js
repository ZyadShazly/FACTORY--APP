// Shared, dependency-free SU operation planning. This is a UI aid, NOT authorization.
// Server-side RPCs must independently verify auth.uid() and record audit history.
export function isSuProfile(profile, authorizedId) {
  return Boolean(authorizedId && profile?.id === authorizedId && profile?.role === "owner" && profile?.status === "active");
}
export function evaluateSuImpact({module,action,before={},after={},dependencies=[]}={}) {
  const changed = Object.keys(after).filter(key => !Object.is(before[key],after[key]))
    .map(key=>({field:key,before:before[key]??null,after:after[key]??null}));
  const linked = dependencies.filter(item=>Number(item?.count)>0).map(item=>({
    label:String(item.label||item.type||"سجلات مرتبطة"),
    count:Number(item.count),
    financial: Boolean(item.financial),
    immutable: Boolean(item.immutable),
  }));
  const destructive = ["delete","hard-delete","reverse","rewrite-posted"].includes(action);
  const highRisk=destructive || linked.some(x=>x.financial||x.immutable);
  const blocked = Boolean((action==="delete"||action==="hard-delete")&&linked.length);
  return {
    module:String(module||"unknown"), action:String(action||"update"),
    changes:changed,linked,
    risk:blocked?"blocked":highRisk?"high":linked.length?"medium":"low",
    allowed:!blocked,
    guidance:blocked?"لا يمكن الحذف مع وجود ارتباطات. استخدم الأرشفة أو عكس الحركات.":highRisk?"يجب التأكد من أثر العملية، ويفضل عكس الحركات المالية بدل مسحها.":"راجع البيانات الجديدة وأكد الحفظ.",
    requiresReason:destructive || changed.length>0 || linked.length>0,
  };
}
export function describeSuImpact(impact){
  const lines=[
    `العملية: ${impact.module} / ${impact.action}`,
    `مستوى المخاطر: ${impact.risk}`,
    ...impact.changes.map(c=>`${c.field}: ${String(c.before)} ← ${String(c.after)}`),
    ...impact.linked.map(x=>`${x.label}: ${x.count}`),
    impact.guidance,
  ];
  return lines.join("\n");
}
