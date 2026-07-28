import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../src/operational/ProcurementWorkspace.jsx', import.meta.url), 'utf8');
const css = await readFile(new URL('../src/operational/procurementPrint.css', import.meta.url), 'utf8');

test('procurement workspace presents one workflow step at a time', () => {
  for (const tab of ['requests','quotes','orders','receipts','invoices']) assert.match(source, new RegExp(`\\["${tab}"`));
  assert.match(source, /tab==="requests"/);
  assert.match(source, /tab==="quotes"/);
  assert.match(source, /tab==="orders"/);
  assert.match(source, /tab==="receipts"/);
  assert.match(source, /tab==="invoices"/);
  assert.match(source, /procurement-tabs/);
});

test('workspace has one sticky primary action and no more than four KPIs', () => {
  assert.match(source, /<PrimaryActionBar primaryAction=/);
  assert.equal((source.match(/<KpiCard /g) || []).length, 4);
  assert.equal((source.match(/>\+ طلب شراء جديد</g) || []).length, 1);
});

test('desktop and mobile layouts avoid unbounded grids', () => {
  assert.match(css, /\.procurement-tabs\s*\{[\s\S]*overflow-x:\s*auto/);
  assert.match(css, /@media \(max-width: 760px\)/);
  assert.match(css, /@media \(max-width: 480px\)/);
  assert.match(css, /\.procurement-document-meta\s*\{[\s\S]*grid-template-columns:\s*repeat\(2/);
});
