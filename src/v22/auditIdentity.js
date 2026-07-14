export function auditActorLabel(row) {
  const fullName = row?.actor?.full_name?.trim();
  if (fullName) return fullName;

  const email = row?.actor?.email?.trim();
  if (email) return email;

  return row?.actor_id || "النظام";
}
