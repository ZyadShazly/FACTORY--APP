import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const page = fs.readFileSync(new URL("../src/assets/AssetsPage.jsx", import.meta.url), "utf8");

test("every custody assignment is partitioned into active work or immutable history", () => {
  const activeStatuses = "draft\",\"pending_receiver_confirmation\",\"issued\",\"partially_returned\",\"settlement_pending";
  assert.match(page, new RegExp(`activeAssignments=.*\\[\\"${activeStatuses}\\"\\]\\.includes`));
  assert.match(page, new RegExp(`archivedAssignments=.*!\\[\\"${activeStatuses}\\"\\]\\.includes`));
});

test("terminal custody rows remain visible in a collapsed audit archive", () => {
  assert.match(page, /import\{ArchiveSection\}from"\.\.\/ui"/);
  assert.match(page, /title="سجل العهد المكتملة والملغاة"/);
  assert.match(page, /العهد المعادة أو المغلقة أو الملغاة أو المعكوسة محفوظة هنا كسجل مراجعة/);
  assert.match(page, /<AssignmentHistory assignments=\{archivedAssignments\} data=\{data\}/);
  assert.match(page, /ASSIGNMENT_STATUS\[a\.status\]\|\|a\.status/);
});

test("custody history exposes quantities and trust without mutation controls", () => {
  const history = page.match(/function AssignmentHistory[\s\S]*?function AssetModal/)?.[0] || "";
  assert.match(history, /ConfirmationBadge method=\{a\.confirmation_method\}/);
  assert.match(history, /returned_quantity/);
  assert.match(history, /settled_quantity/);
  assert.doesNotMatch(history, /renewLink|setReturnForm|AssignmentEmergencyActions|Button/);
});
