import { readFile, writeFile } from "node:fs/promises";

async function patch(path, transform) {
  const before = await readFile(path, "utf8");
  const after = transform(before);
  if (after !== before) await writeFile(path, after);
}

await patch("src/App.jsx", (source) => {
  const needle = 'else if (key === "auditLog") {';
  if (source.includes('key === "assetAlerts"')) return source;
  if (!source.includes(needle)) throw new Error("App asset-alert patch anchor missing");
  return source.replace(
    needle,
    'else if (key === "assetAlerts") fetchResult = await withTimeout(supabase.rpc("get_asset_alerts_visible"), undefined, "انتهت مهلة تحميل تنبيهات الأصول");\n  ' + needle,
  );
});

await patch("src/v23/workCalendar.jsx", (source) => {
  if (source.includes("calendarApprovalSummary")) return source;
  const stateAnchor = '  const canManage=permissions.payroll_calendar_manage, canApprove=permissions.payroll_calendar_approve;';
  const stateReplacement = `${stateAnchor}\n  const draftSchedules=(data.workSchedules||[]).filter(s=>s.status==="draft");\n  const activeSchedules=(data.workSchedules||[]).filter(s=>s.status==="active");\n  const calendarApprovalSummary=true;`;
  if (!source.includes(stateAnchor)) throw new Error("Calendar state patch anchor missing");
  source = source.replace(stateAnchor, stateReplacement);

  const uiAnchor = '    <ErrorState error={error}/><SuccessState message={success}/>';
  const uiReplacement = `${uiAnchor}\n    {calendarApprovalSummary&&activeSchedules.length===0&&<div className="v22-alert error"><b>لا يوجد جدول عمل مفعّل حاليًا.</b> {draftSchedules.length>0?<>يوجد {draftSchedules.length} جدول مسودة ينتظر الاعتماد. <Button variant="ghost" onClick={()=>setView("schedules")}>فتح جداول العمل للاعتماد</Button></>:<>أنشئ جدول العمل الافتراضي ثم اعتمده.</>}</div>}\n    {calendarApprovalSummary&&activeSchedules.length>0&&<div className="v22-alert info">جدول العمل المفعّل: <b>{activeSchedules.map(s=>s.name).join("، ")}</b></div>}`;
  if (!source.includes(uiAnchor)) throw new Error("Calendar UI patch anchor missing");
  return source.replace(uiAnchor, uiReplacement);
});
