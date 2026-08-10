import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { readWorkspaceLocation, workspaceUrl, safeProjectId } from "../src/app/urlNavigation.js";

test("UAT-009 encodes page and project context in a refresh-safe URL", () => {
  assert.deepEqual(readWorkspaceLocation("?page=projects&project=p1"), { page: "projects", projectId: "p1" });
  assert.equal(workspaceUrl({ page: "projects", projectId: "p1" }, "https://example.test/app?demo=v22"), "/app?demo=v22&page=projects&project=p1");
  assert.equal(workspaceUrl({ page: "inventory" }, "https://example.test/app?page=projects&project=p1"), "/app?page=inventory");
  assert.equal(safeProjectId("p1", [{ id: "p1" }]), "p1");
  assert.equal(safeProjectId("missing", [{ id: "p1" }]), null);
});

test("App listens for Back/Forward and routes project selections", () => {
  const app = fs.readFileSync("src/AppMonolith.jsx", "utf8");
  assert.match(app, /addEventListener\("popstate"/);
  assert.match(app, /window\.history\.pushState/);
  assert.match(app, /initialProjectId=\{routeProjectId\}/);
});
