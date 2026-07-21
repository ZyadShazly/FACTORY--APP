import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const files = {
  hr: "src/modules/hr/index.js",
  payroll: "src/modules/payroll/index.js",
  calendar: "src/modules/calendar/index.js",
};

test("descriptive module boundaries remain available during legacy folder migration", () => {
  for (const [name, path] of Object.entries(files)) {
    assert.ok(fs.existsSync(path), `${name} compatibility boundary must exist`);
    const source = fs.readFileSync(path, "utf8");
    assert.match(source, /export\s+\{/);
  }
});
