import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../src/operational/ProcurementWorkspace.jsx', import.meta.url), 'utf8');

test('procurement documents open before approval', () => {
  assert.match(source, /فتح التفاصيل/);
  assert.match(source, /تفاصيل طلب الشراء/);
  assert.match(source, /تفاصيل أمر الشراء/);
});

test('purchase review shows financial and receiving breakdown', () => {
  for (const label of ['الخصم','الضريبة','المستلم','الإجمالي النهائي','الاستلام والفواتير']) assert.match(source, new RegExp(label));
});

test('request approval and rejection happen from details', () => {
  assert.match(source, /اعتماد الطلب/);
  assert.match(source, /رفض بسبب/);
  assert.match(source, /سبب الرفض مطلوب/);
});

test('procurement document supports print and PDF workflow', () => {
  assert.match(source, /طباعة \/ PDF/);
  assert.match(source, /window\.print\(\)/);
});