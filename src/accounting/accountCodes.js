export function compactAccountCode(value) {
  return String(value || "").replace(/\./g, "");
}

export function accountMatchesLookup(account, query) {
  const raw = String(query || "").trim().toLowerCase();
  if (!raw) return true;

  const compactQuery = raw.replace(/\./g, "");
  const rawCode = String(account?.account_code || "").toLowerCase();
  const compactCode = compactAccountCode(rawCode).toLowerCase();
  const names = [
    account?.name_ar,
    account?.name_en,
  ].filter(Boolean).join(" ").toLowerCase();

  return rawCode.includes(raw)
    || compactCode.includes(compactQuery)
    || names.includes(raw);
}
