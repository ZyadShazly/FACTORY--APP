import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const status = fs.readFileSync("docs/CURRENT_SYSTEM_STATUS.md", "utf8");
const evidence = fs.readFileSync("docs/EP_04_ASSETS_OPERATIONAL_CLOSEOUT.md", "utf8");

test("current roadmap records EP-04 as Pilot-closeout rather than future work", () => {
  assert.match(status, /\| Assets \| Operationally closed for Pilot in EP-04 \|/);
  assert.match(status, /EP-04 Assets Operational Closeout/);
  assert.match(evidence, /EP-04 is complete/);
  assert.match(evidence, /EP-05 — Commercial Lifecycle/);
});

test("closeout evidence preserves honest deferred boundaries", () => {
  for (const boundary of [
    "maintenance-management product",
    "vehicle fleet module",
    "depreciation engine",
    "paid WhatsApp provider",
    "external OTP provider",
  ]) {
    assert.match(evidence, new RegExp(boundary));
  }
  assert.match(evidence, /accepted-with-controls boundaries, not unresolved defects/);
});

test("closeout evidence contains reproducible live and CI results without data mutation", () => {
  assert.match(evidence, /17 immutable ledger movements/);
  assert.match(evidence, /0 balance reconciliation mismatches/);
  assert.match(evidence, /34 new covering indexes installed/);
  assert.match(evidence, /0 remaining Supabase Advisor `unindexed_foreign_keys`/);
  assert.match(evidence, /No Asset, assignment, return, settlement, or movement row was inserted/);
  assert.match(evidence, /Quality Gate: passed for PRs #111, #112, and #113/);
});
