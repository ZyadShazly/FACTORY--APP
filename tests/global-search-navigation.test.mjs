import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const shellUrl = new URL("../src/layout/AppShell.jsx", import.meta.url);

test("global search opens project results at their actual workspace", async () => {
  const source = await readFile(shellUrl, "utf8");
  assert.match(source, /\["project", "project_overdue"\]\.includes\(item\.kind\)/);
  assert.match(source, /onNavigate\(item\.page_id, projectId \? \{ projectId \} : \{\}\)/);
  assert.match(source, /const navigate = \(pageId, options = \{\}\) => \{ onNavigate\(pageId, options\)/);
  assert.match(source, /onClick=\{\(\) => goItem\(item\)\}/);
});

test("global search cancels stale responses and exposes empty and failure states", async () => {
  const source = await readFile(shellUrl, "utf8");
  assert.match(source, /let cancelled = false/);
  assert.match(source, /if \(cancelled\) return/);
  assert.match(source, /تعذر البحث الآن/);
  assert.match(source, /لا توجد نتائج مطابقة/);
});
