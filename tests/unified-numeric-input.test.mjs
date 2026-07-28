import test from"node:test";
import assert from"node:assert/strict";
import fs from"node:fs";

const numeric=fs.readFileSync("src/ui/NumericInput.jsx","utf8");
const operationalUi=fs.readFileSync("src/operational/ui.jsx","utf8");

test("numeric input uses decimal keyboard without native number spinners",()=>{
  assert.match(numeric,/type="text"/);
  assert.match(numeric,/inputMode="decimal"/);
  assert.doesNotMatch(numeric,/type="number"/);
});

test("numeric input preserves decimal fractions and normalizes Arabic separators",()=>{
  assert.match(numeric,/replace\(\/\[٫,\]\/g,"\."\)/);
  assert.match(numeric,/replace\(\/\[٠-٩\]\/g/);
});

test("operational numeric fields are upgraded through the shared component",()=>{
  assert.match(operationalUi,/children\.props\.type==="number"/);
  assert.match(operationalUi,/<NumericInput \{\.\.\.children\.props\}\/>/);
});
