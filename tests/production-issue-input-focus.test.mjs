import test from"node:test";
import assert from"node:assert/strict";
import{readFileSync}from"node:fs";

test("production issue quantity input keeps numeric caret direction stable",()=>{
  const css=readFileSync(new URL("../src/operational/productionWorkspace.css",import.meta.url),"utf8");
  assert.match(css,/\.production-inline-action input\[type="number"\]\{[^}]*direction:ltr[^}]*text-align:right/);
});
