import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const workflow = fs.readFileSync(".github/workflows/temporary-app-materializer.yml", "utf8");

test("temporary materializer is scoped away from main", () => {
  assert.match(workflow, /github\.head_ref == 'refactor\/app-bootstrap-wiring'/);
  assert.match(workflow, /automation\/materialized-app-bootstrap-output/);
  assert.doesNotMatch(workflow, /git push[^\n]*HEAD:refs\/heads\/main/);
});
