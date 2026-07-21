import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { normalizeInternationalPhone, whatsappMessage, whatsappUrl } from "../src/assets/domain.js";

const payroll = fs.readFileSync(new URL("../src/v22/payroll.jsx", import.meta.url), "utf8");
const assetsPage = fs.readFileSync(new URL("../src/assets/AssetsPage.jsx", import.meta.url), "utf8");
const migration = fs.readFileSync(new URL("../supabase/migrations/20260721090000_employee_whatsapp_assets.sql", import.meta.url), "utf8");

test("employee creation requires an international WhatsApp number", () => {
  assert.match(payroll, /label="رقم واتساب \(إجباري\)"/);
  assert.match(payroll, /placeholder="\+9665XXXXXXXX"/);
  assert.match(payroll, /\^\\\+\[1-9\]\[0-9\]\{7,14\}\$/);
});

test("database protects new employee phone data without rewriting legacy rows", () => {
  assert.match(migration, /employees_validate_whatsapp_phone/);
  assert.match(migration, /employees_phone_normalized_unique/);
  assert.match(migration, /رقم واتساب الموظف مطلوب بصيغة دولية/);
  assert.doesNotMatch(migration, /update\s+public\.employees\s+set\s+phone/i);
});

test("asset issuance returns and immediately consumes the employee WhatsApp number", () => {
  assert.match(migration, /'receiver_phone',\s*whatsapp_phone/);
  assert.match(migration, /receiver_phone_snapshot/);
  assert.match(assetsPage, /result\.receiver_phone\|\|phone/);
  assert.match(assetsPage, /whatsappUrl\(share\.phone,share\.message\)/);
});

test("international phone normalization is deterministic", () => {
  assert.equal(normalizeInternationalPhone("00966 55 000 0001"), "+966550000001");
  assert.equal(normalizeInternationalPhone("+20 106 496 9494"), "+201064969494");
  assert.equal(normalizeInternationalPhone("0500000000"), "");
});

test("WhatsApp deep link targets the employee and includes a clear custody message", () => {
  const message = whatsappMessage({ code: "AST-100", url: "https://example.com/confirm", receiverName: "أحمد" });
  const target = whatsappUrl("+966550000001", message);
  assert.match(message, /السلام عليكم أحمد/);
  assert.match(message, /AST-100/);
  assert.match(message, /لا تقم بإعادة إرساله/);
  assert.match(target, /^https:\/\/wa\.me\/966550000001\?text=/);
});
