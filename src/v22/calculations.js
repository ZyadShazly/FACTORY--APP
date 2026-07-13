export const numeric = (value) => Number.isFinite(Number(value)) ? Number(value) : 0;

export function calculateNetSalary(row) {
  return numeric(row.base_salary) + numeric(row.housing_allowance) + numeric(row.transport_allowance)
    + numeric(row.other_allowance) + numeric(row.overtime_hours) * numeric(row.overtime_rate)
    + numeric(row.bonuses) - numeric(row.deductions) - numeric(row.advances);
}

export function calculateDailyLabor({ start_time, end_time, break_minutes = 0, hourly_rate = 0, overtime_hours = 0, overtime_rate = 0 }) {
  if (!start_time || !end_time) return { totalHours: 0, normalHours: 0, overtimeAmount: 0, totalAmount: 0 };
  const [sh, sm] = start_time.split(":").map(Number);
  const [eh, em] = end_time.split(":").map(Number);
  let minutes = eh * 60 + em - (sh * 60 + sm);
  if (minutes <= 0) minutes += 24 * 60;
  const totalHours = Math.max(0, (minutes - numeric(break_minutes)) / 60);
  const overtime = Math.min(totalHours, numeric(overtime_hours));
  const normalHours = Math.max(0, totalHours - overtime);
  const overtimeAmount = overtime * numeric(overtime_rate);
  const totalAmount = normalHours * numeric(hourly_rate) + overtimeAmount;
  return {
    totalHours: Number(totalHours.toFixed(2)), normalHours: Number(normalHours.toFixed(2)),
    overtimeAmount: Number(overtimeAmount.toFixed(2)), totalAmount: Number(totalAmount.toFixed(2)),
  };
}
