import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const workspace = await readFile(new URL('../src/operational/ProcurementWorkspace.jsx', import.meta.url), 'utf8');

test('purchase requests are split into active work and collapsed history', () => {
  assert.match(workspace, /REQUEST_ACTIVE=new Set\(\["draft","submitted","approved"\]\)/);
  assert.match(workspace, /activeRequests/);
  assert.match(workspace, /previousRequests/);
  assert.match(workspace, /<ArchiveSection title="طلبات الشراء السابقة"/);
  assert.match(workspace, /المحولة والمكتملة والمرفوضة محفوظة هنا ولا تُحذف/);
});

test('display name is primary and internal serial remains secondary', () => {
  assert.match(workspace, /row\?\.display_name\|\|row\?\.\[serialKey\]/);
  assert.match(workspace, /المرجع الداخلي:/);
  assert.match(workspace, /display_name:request\.display_name/);
  assert.match(workspace, /create_purchase_order_draft_from_quote/);
  assert.match(workspace, /order_display_name:draftOrder\.display_name\.trim\(\)/);
});

test('request details expose immutable lifecycle history', () => {
  assert.match(workspace, /request_history:\[\]/);
  assert.match(workspace, /workspace\.request_history\.filter/);
  assert.match(workspace, /سجل الحالة والتدقيق/);
  assert.match(workspace, /entry\.reason/);
});

test('legacy request actions remain available only in valid states', () => {
  assert.match(workspace, /row\.status==="draft"/);
  assert.match(workspace, /row\.status==="submitted"/);
  assert.match(workspace, /submit_purchase_request/);
  assert.match(workspace, /decide_purchase_request/);
});
