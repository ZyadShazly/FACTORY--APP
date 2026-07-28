import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const css = fs.readFileSync('src/operational/procurementPrint.css', 'utf8');
const workspace = fs.readFileSync('src/operational/ProcurementWorkspace.jsx', 'utf8');
const main = fs.readFileSync('src/main.jsx', 'utf8');

test('print stylesheet is loaded and isolates one selected document', () => {
  assert.match(main, /operational\/procurementPrint\.css/);
  assert.match(workspace, /className="procurement-print-document"/);
  assert.match(css, /body \*\s*\{[\s\S]*visibility:\s*hidden/);
  assert.match(css, /\.procurement-print-document,[\s\S]*visibility:\s*visible/);
  assert.match(css, /\[data-print-hidden\],[\s\S]*display:\s*none/);
});

test('print layout is A4 RTL and avoids trailing blank layout', () => {
  assert.match(css, /@page\s*\{[\s\S]*size:\s*A4 portrait/);
  assert.match(css, /#root\s*\{[\s\S]*height:\s*0 !important/);
  assert.match(css, /\.procurement-print-document\s*\{[\s\S]*position:\s*absolute !important/);
  assert.match(css, /direction:\s*rtl/);
  assert.match(css, /table-header-group/);
  assert.match(css, /break-inside:\s*avoid/);
});

test('preview and print retain logo, totals, VAT, and signatures', () => {
  assert.match(workspace, /src="\/logo\.png"/);
  for (const className of ['procurement-document-header','procurement-document-meta','procurement-document-totals','procurement-document-signatures']) {
    assert.match(workspace, new RegExp(className));
    assert.match(css, new RegExp(`\\.${className}`));
  }
  assert.match(workspace, /ضريبة القيمة المضافة/);
  assert.match(workspace, /window\.print\(\)/);
});
