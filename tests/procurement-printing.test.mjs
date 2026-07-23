import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const css = fs.readFileSync("src/operational/procurementPrint.css", "utf8");
const main = fs.readFileSync("src/main.jsx", "utf8");
const workspace = fs.readFileSync("src/operational/ProcurementWorkspace.jsx", "utf8");

test("procurement printing isolates the selected document", () => {
  assert.match(css, /@media print/);
  assert.match(css, /body \*\s*\{[\s\S]*visibility:\s*hidden/);
  assert.match(css, /\.procurement-print-document,[\s\S]*visibility:\s*visible/);
  assert.match(css, /\.procurement-print-document button\s*\{[\s\S]*display:\s*none/);
  assert.match(css, /max-height:\s*none/);
  assert.match(css, /overflow:\s*visible/);
});

test("print stylesheet is loaded and procurement document keeps its print hook", () => {
  assert.match(main, /operational\/procurementPrint\.css/);
  assert.match(workspace, /className="procurement-print-document"/);
  assert.match(workspace, /window\.print\(\)/);
});
