import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const app=fs.readFileSync("src/AppMonolith.jsx","utf8");
const shared=fs.readFileSync("src/v22/shared.jsx","utf8");
const labor=fs.readFileSync("src/v22/dailyLabor.jsx","utf8");

test("UAT-012 critical icon controls have accessible names and dialog focus behavior",()=>{
  assert.match(app,/aria-label=\{`حذف \$\{m\?\.name/);
  assert.match(app,/aria-label=\{`تعديل \$\{p\.name\}`\}/);
  assert.match(labor,/aria-label=\{`حذف مسودة وردية/);
  assert.match(shared,/aria-labelledby=\{titleId\}/);
  assert.match(shared,/reasonRef\.current\?\.focus/);
  assert.match(shared,/event\.key === "Escape"/);
});
