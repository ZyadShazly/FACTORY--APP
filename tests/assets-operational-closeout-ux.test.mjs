import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { whatsappMessage } from "../src/assets/domain.js";

const page = fs.readFileSync(new URL("../src/assets/AssetsPage.jsx", import.meta.url), "utf8");

test("linked employees receive truthful authenticated confirmation guidance", () => {
  const message = whatsappMessage({
    code: "CST-1",
    url: "https://example.com/confirm",
    receiverName: "أحمد",
    confirmationMethod: "authenticated_employee",
  });
  assert.match(message, /سجّل الدخول بحسابك المرتبط بالموظف/);
  assert.doesNotMatch(message, /هذا الرابط مخصص لك/);
  assert.match(page, /confirmationMethod=linkedProfile\?"authenticated_employee":"bearer_link"/);
  assert.match(page, /authenticated\?"authenticated-trust":"bearer-trust-warning"/);
  assert.match(page, /تأكيد موثّق بحساب الموظف/);
});

test("unlinked employees retain bearer-link warning and private-link message", () => {
  const message = whatsappMessage({ code: "CST-2", url: "https://example.com/confirm" });
  assert.match(message, /هذا الرابط مخصص لك، فلا تقم بإعادة إرساله/);
  assert.match(page, /تأكيد عبر رابط غير موثّق بالهوية/);
});

test("issue link renewal exposes one WhatsApp action instead of duplicate controls", () => {
  assert.equal((page.match(/إرسال\/إعادة إرسال واتساب/g) || []).length, 2);
  assert.doesNotMatch(page, /إرسال\/إعادة إرسال الرابط/);
});

test("return and renewal flows derive trust from the stored receiver profile", () => {
  assert.match(page, /confirmationMethod=ass\?\.receiver_profile_id\?"authenticated_employee":"bearer_link"/);
  assert.match(page, /confirmationMethod=assignment\?\.receiver_profile_id\?"authenticated_employee":"bearer_link"/);
});
