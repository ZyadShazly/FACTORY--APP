export const HOLIDAY_TYPES = Object.freeze({
  official_holiday: { label: "عطلة رسمية", tone: "official" },
  company_holiday: { label: "عطلة الشركة", tone: "company" },
  weekly_off_override: { label: "راحة استثنائية", tone: "weekly" },
  half_day: { label: "نصف يوم", tone: "half" },
  working_day_override: { label: "يوم عمل استثنائي", tone: "working" },
});

export const ISO_WEEKDAYS = Object.freeze([
  [7, "الأحد"], [1, "الاثنين"], [2, "الثلاثاء"], [3, "الأربعاء"],
  [4, "الخميس"], [5, "الجمعة"], [6, "السبت"],
]);

export function localDateKey(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

export function monthCells(year, monthIndex) {
  const first = new Date(year, monthIndex, 1);
  const offset = first.getDay();
  const count = new Date(year, monthIndex + 1, 0).getDate();
  return [
    ...Array.from({ length: offset }, () => null),
    ...Array.from({ length: count }, (_, index) => localDateKey(new Date(year, monthIndex, index + 1))),
  ];
}

export function dateRangeDays(start, end) {
  if (!start || !end) return 0;
  const [sy, sm, sd] = start.split("-").map(Number);
  const [ey, em, ed] = end.split("-").map(Number);
  return Math.floor((Date.UTC(ey, em - 1, ed) - Date.UTC(sy, sm - 1, sd)) / 86400000) + 1;
}

export function shiftMinutes(start, end, spansNextDay = false) {
  if (!start || !end) return 0;
  const toMinutes = (value) => { const [h, m] = value.split(":").map(Number); return h * 60 + m; };
  return toMinutes(end) - toMinutes(start) + (spansNextDay ? 1440 : 0);
}

export function validateShift(day) {
  if (!day.is_working_day) return null;
  const duration = shiftMinutes(day.required_start_time, day.required_end_time, day.spans_next_day);
  if (duration <= 0) return "حدد وقت وردية صحيحًا، وفعل تجاوز منتصف الليل عند الحاجة.";
  if (Number(day.break_minutes) >= duration) return "مدة الاستراحة يجب أن تكون أقل من مدة الوردية.";
  if (Number(day.required_minutes) <= 0 || Number(day.required_minutes) > duration - Number(day.break_minutes || 0)) return "دقائق العمل المطلوبة يجب أن تقع داخل صافي مدة الوردية.";
  return null;
}

export function canApproveCalendar(profile, createdBy, permissions) {
  if (!permissions?.payroll_calendar_approve) return false;
  return ["owner", "manager"].includes(profile?.role) || createdBy !== profile?.id;
}
