import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../src/operational/ProcurementWorkspace.jsx', import.meta.url), 'utf8');

test('all four procurement documents open in the shared preview', () => {
  for (const type of ['request','order','receipt','invoice']) {
    assert.match(source, new RegExp(`openDocument\\("${type}"`));
    assert.match(source, new RegExp(`${type}:\\{title:`));
  }
  assert.match(source, /المعاينة هي نفس محتوى الطباعة/);
  assert.match(source, /data-document-type=\{type\}/);
});

test('professional preview includes identity, commercial totals, VAT, and signatures', () => {
  for (const token of ['/logo.png','المرجع الداخلي','المشروع','المورد','سعر الوحدة','ضريبة القيمة المضافة','الإجمالي النهائي','الاسم / التوقيع']) {
    assert.match(source, new RegExp(token.replace('/', '\\/')));
  }
  assert.match(source, /formatMoney/);
  assert.match(source, /getCurrencySettings/);
  assert.doesNotMatch(source, /currency:"SAR"/);
});

test('approval and sending are only offered from document preview', () => {
  assert.match(source, /type==="request"&&row\.status==="submitted"/);
  assert.match(source, /type==="order"&&row\.status==="draft"/);
  assert.match(source, /type==="order"&&row\.status==="approved"/);
  assert.match(source, /اعتماد بعد المعاينة/);
  assert.match(source, /إرسال بعد المعاينة/);
  assert.match(source, /approve_purchase_order/);
  assert.match(source, /mark_purchase_order_sent/);
});

test('request rejection records a mandatory reason', () => {
  assert.match(source, /سبب الرفض مطلوب/);
  assert.match(source, /decide_purchase_request/);
  assert.match(source, /reason:rejectReason\.trim\(\)/);
});
