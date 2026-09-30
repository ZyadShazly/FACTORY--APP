import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const matrix=fs.readFileSync("docs/accounting-integration-matrix.md","utf8");

test("cash transfer matrix does not invent a non-existent operational source",()=>{
  assert.match(matrix,/Bank\/Cash transfer/);
  assert.match(matrix,/there is no canonical Bank\/Cash transfer transaction in the current operational model/);
  assert.match(matrix,/No GL is invented until such an operational source exists/);
});

test("inventory warehouse transfers are not mislabeled as financial cash transfers",()=>{
  assert.match(matrix,/current app has inventory warehouse transfers/);
});
