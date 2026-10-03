import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const code=fs.readFileSync("src/accounting/accountCodes.js","utf8");

test("compact account code removes presentation dots only",()=>{
  assert.match(code,/replace\(\/\\\.\/g, ""\)/);
});

test("account lookup accepts both dotted and compact code text plus names",()=>{
  assert.match(code,/rawCode\.includes\(raw\)/);
  assert.match(code,/compactCode\.includes\(compactQuery\)/);
  assert.match(code,/names\.includes\(raw\)/);
});
