export function auditActorLabel(row) {
  const fullName = row?.actor?.full_name?.trim();
  const email = row?.actor?.email?.trim();

  if (fullName && email) return `${fullName} · ${email}`;
  if (fullName) return fullName;
  if (email) return email;

  return row?.actor_id || "النظام";
}
