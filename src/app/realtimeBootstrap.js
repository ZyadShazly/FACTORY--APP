import { REALTIME_TABLE_TO_KEY, combinedRealtimeStatus } from "../realtime.js";

export function realtimeTablesForKeys(keys = []) {
  const allowed = new Set(keys);
  return Object.entries(REALTIME_TABLE_TO_KEY)
    .filter(([, key]) => allowed.has(key))
    .map(([table, key]) => ({ table, key }));
}

export function buildRealtimeChannelPlan({ role, dataKeys = [], includeSignals = true } = {}) {
  const entries = realtimeTablesForKeys(dataKeys);
  const filtered = includeSignals
    ? entries
    : entries.filter(({ key }) => !["assetRealtimeSignal", "projectRealtimeSignal"].includes(key));

  return filtered.map(({ table, key }) => ({
    id: `${role || "unknown"}:${table}`,
    table,
    key,
    schema: "public",
    event: "*",
  }));
}

export function nextRealtimeState(statusByChannel = {}) {
  return combinedRealtimeStatus(statusByChannel);
}

export function applyRealtimePayload(currentData, payload, key) {
  const rows = Array.isArray(currentData?.[key]) ? currentData[key] : [];
  const eventType = payload?.eventType;
  const nextRow = payload?.new;
  const oldRow = payload?.old;

  if (eventType === "INSERT" && nextRow?.id) {
    return { ...currentData, [key]: [...rows.filter((row) => row.id !== nextRow.id), nextRow] };
  }

  if (eventType === "UPDATE" && nextRow?.id) {
    return { ...currentData, [key]: rows.map((row) => (row.id === nextRow.id ? { ...row, ...nextRow } : row)) };
  }

  if (eventType === "DELETE" && oldRow?.id) {
    return { ...currentData, [key]: rows.filter((row) => row.id !== oldRow.id) };
  }

  return currentData;
}
