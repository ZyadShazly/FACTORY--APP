import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const payroll = fs.readFileSync(new URL("../src/v22/payroll.jsx", import.meta.url), "utf8");
const migration = fs.readFileSync(new URL("../supabase/migrations/20260721112000_employee_whatsapp_assets.sql", import.meta.url), "utf8");

test("employee creation requires a WhatsApp number in the UI", () => {
  assert.match(payroll, /label="رقم واتساب"/);
  assert.match(payroll, /required inputMode="tel"/);
  assert.match(payroll, /phone\.length<8\|\|phone\.length>15/);
});

test("database protects new employee phone data", () => {
  assert.match(migration, /employees_validate_whatsapp_phone/);
  assert.match(migration, /employees_phone_normalized_unique/);
  assert.match(migration, /between 8 and 15/);
});

test("asset issuance snapshots and returns the employee WhatsApp number", () => {
  assert.match(migration, /receiver_phone_snapshot/);
  assert.match(migration, /'receiver_phone',ass\.receiver_phone_snapshot/);
  assert.match(migration, /لا يمكن إصدار العهدة قبل تسجيل رقم واتساب صحيح/);
});
