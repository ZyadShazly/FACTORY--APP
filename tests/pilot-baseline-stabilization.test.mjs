import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const cleanTreeScript = fs.readFileSync("scripts/assert-clean-working-tree.mjs", "utf8");
const qualityGate = fs.readFileSync(".github/workflows/quality-gate.yml", "utf8");

test("quality gate uses current Node 24-based GitHub actions", () => {
  assert.match(qualityGate, /actions\/checkout@v7/);
  assert.match(qualityGate, /actions\/setup-node@v7/);
  assert.match(qualityGate, /actions\/upload-artifact@v7/);
  assert.doesNotMatch(qualityGate, /actions\/(?:checkout|setup-node|upload-artifact)@v4/);
  assert.match(qualityGate, /pull_request:\s*\{\}/);
});

test("clean-tree gate includes untracked files", () => {
  assert.match(cleanTreeScript, /--untracked-files=all/);
  assert.doesNotMatch(cleanTreeScript, /--untracked-files=no/);
});

test("clean-tree gate fails when a test leaves an untracked artifact", () => {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "factory-clean-tree-"));
  try {
    fs.mkdirSync(path.join(fixtureRoot, "scripts"), { recursive: true });
    fs.writeFileSync(path.join(fixtureRoot, "scripts", "assert-clean-working-tree.mjs"), cleanTreeScript);

    const runGit = (args) => spawnSync("git", args, { cwd: fixtureRoot, encoding: "utf8" });
    assert.equal(runGit(["init"]).status, 0);
    assert.equal(runGit(["add", "scripts/assert-clean-working-tree.mjs"]).status, 0);
    assert.equal(runGit(["-c", "user.name=Baseline Test", "-c", "user.email=baseline@example.invalid", "commit", "-m", "fixture"]).status, 0);

    const clean = spawnSync(process.execPath, ["scripts/assert-clean-working-tree.mjs"], { cwd: fixtureRoot, encoding: "utf8" });
    assert.equal(clean.status, 0, clean.stderr || clean.stdout);

    fs.writeFileSync(path.join(fixtureRoot, "test-output.log"), "unexpected artifact");
    const dirty = spawnSync(process.execPath, ["scripts/assert-clean-working-tree.mjs"], { cwd: fixtureRoot, encoding: "utf8" });
    assert.equal(dirty.status, 1, dirty.stderr || dirty.stdout);
    assert.match(dirty.stderr, /\?\? test-output\.log/);
  } finally {
    fs.rmSync(fixtureRoot, { recursive: true, force: true });
  }
});
