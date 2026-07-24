import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const workspace = await readFile(new URL('../src/operational/ProcurementWorkspace.jsx', import.meta.url), 'utf8');

test('purchase requests are grouped by the complete lifecycle', () => {
  for (const status of ['draft','submitted','approved','converted','completed','rejected']) {
    assert.match(workspace, new RegExp(`status:\"${status}\"`));
    assert.match(workspace, new RegExp(`data-request-stage=\\{stage\\.status\\}`));
  }
  assert.match(workspace, /Pending Approval — بانتظار الاعتماد/);
  assert.match(workspace, /Converted To PO — محول إلى أمر شراء/);
  assert.match(workspace, /Completed — مكتمل/);
});

test('request details expose immutable lifecycle history', () => {
  assert.match(workspace, /request_history:\[\]/);
  assert.match(workspace, /ws\.request_history\.filter/);
  assert.match(workspace, /data-request-history/);
  assert.match(workspace, /سجل دورة الطلب/);
  assert.match(workspace, /entry\.reason/);
});

test('legacy request actions remain available only in valid states', () => {
  assert.match(workspace, /row\.status===\"draft\"/);
  assert.match(workspace, /selected\.row\.status===\"submitted\"/);
  assert.match(workspace, /submit_purchase_request/);
  assert.match(workspace, /decide_purchase_request/);
});
