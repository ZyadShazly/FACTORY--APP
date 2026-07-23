import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const appEntry = await readFile(new URL("../src/App.jsx", import.meta.url), "utf8");

test("application entry lazy-loads the monolith behind Suspense", () => {
  assert.match(appEntry, /lazy\(\(\) => import\("\.\/AppMonolith\.jsx"\)\)/);
  assert.match(appEntry, /<Suspense fallback=\{<AppLoadingFallback \/>\}>/);
  assert.match(appEntry, /<AppMonolith \/>/);
});

test("loading fallback is accessible and Arabic-first", () => {
  assert.match(appEntry, /dir="rtl"/);
  assert.match(appEntry, /role="status"/);
  assert.match(appEntry, /aria-live="polite"/);
  assert.match(appEntry, /جاري تحميل NextEP/);
});
