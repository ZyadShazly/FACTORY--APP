import test from "node:test";
import assert from "node:assert/strict";
import { calculateDailyLabor, calculateNetSalary } from "../src/v22/calculations.js";

test("حساب صافي الراتب يشمل البدلات والإضافي والخصومات والسلف", () => {
  assert.equal(calculateNetSalary({ base_salary: 5000, housing_allowance: 1000, transport_allowance: 500, other_allowance: 250, overtime_hours: 10, overtime_rate: 50, bonuses: 300, deductions: 200, advances: 400 }), 6950);
});

test("وردية 12:00 إلى 20:00 تساوي 8 ساعات و200", () => {
  assert.deepEqual(calculateDailyLabor({ start_time: "12:00", end_time: "20:00", break_minutes: 0, hourly_rate: 25 }), { totalHours: 8, normalHours: 8, overtimeAmount: 0, totalAmount: 200 });
});

test("يدعم الوردية التي تتجاوز منتصف الليل", () => {
  assert.deepEqual(calculateDailyLabor({ start_time: "22:00", end_time: "06:00", break_minutes: 60, hourly_rate: 20, overtime_hours: 2, overtime_rate: 30 }), { totalHours: 7, normalHours: 5, overtimeAmount: 60, totalAmount: 160 });
});
