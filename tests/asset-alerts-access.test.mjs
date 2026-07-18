import test from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";

const migrationUrl = new URL("../supabase/migrations/202607180005_fix_asset_alerts_access.sql", import.meta.url);
const appUrl = new URL("../src/App.jsx", import.meta.url);
const manifestUrl = new URL("../public/manifest.webmanifest", import.meta.url);
const indexUrl = new URL("../index.html", import.meta.url);

test("asset_alerts is an owner-executed permission-filtered safe projection", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  const definition = sql.match(/create or replace view public\.asset_alerts[\s\S]*?;\s*\n\s*revoke/i)?.[0] || "";
  assert.match(definition, /security_barrier\s*=\s*true/i);
  assert.doesNotMatch(definition, /security_invoker\s*=\s*true/i);
  assert.match(definition, /security_invoker\s*=\s*false/i);
  assert.match(definition, /public\.has_permission\('assets_view'\)/i);
  assert.match(definition, /select alerts\.alert_type,[\s\S]*alerts\.created_at[\s\S]*from \(/i);
  const projection = definition.match(/select([\s\S]*?)from \(/i)?.[1] || "";
  assert.deepEqual([...projection.matchAll(/alerts\.(\w+)/g)].map((match) => match[1]), ["alert_type", "reference_id", "title", "due_at", "severity", "created_at"]);
  assert.doesNotMatch(definition, /purchase_cost|supplier_id|receiver_phone_snapshot|\bnotes\b|confirmation_(?:token|hash)/i);
  assert.match(sql, /comment on view public\.asset_alerts[\s\S]*non-financial[\s\S]*assets_view permission check/i);
});

test("asset_alerts grants only authenticated view access and keeps assets revoked", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  assert.match(sql, /revoke all on table public\.asset_alerts from public, anon/i);
  assert.match(sql, /grant select on table public\.asset_alerts to authenticated/i);
  assert.match(sql, /revoke select on table public\.assets from public, anon, authenticated/i);

  const migrationsDir = new URL("../supabase/migrations/", import.meta.url);
  const files = (await readdir(migrationsDir)).filter((name) => name.endsWith(".sql"));
  const allSql = (await Promise.all(files.map((name) => readFile(new URL(name, migrationsDir), "utf8")))).join("\n");
  assert.doesNotMatch(allSql, /grant\s+select\s+on\s+(?:table\s+)?public\.assets(?:\s|,)\s*to\s+authenticated/i);
  assert.doesNotMatch(allSql, /access-control-allow-origin\s*[:=]\s*["']?\*/i);
});

test("assetAlerts keeps its retryable data key but displays an Arabic resource label", async () => {
  const app = await readFile(appUrl, "utf8");
  assert.match(app, /assetAlerts:\s*"تنبيهات الأصول"/);
  assert.match(app, /TABLES\[key\]/);
  assert.match(app, /onClick=\{retryVisibleData\}/);
  assert.match(app, /dataWarnings\.map\(\(key\) => PAGE_LABELS\[key\] \|\| key\)/);
});

test("web manifest and its document reference are valid", async () => {
  const manifest = JSON.parse(await readFile(manifestUrl, "utf8"));
  const html = await readFile(indexUrl, "utf8");
  assert.equal(manifest.start_url, "/");
  assert.equal(manifest.display, "standalone");
  assert.ok(Array.isArray(manifest.icons) && manifest.icons.length >= 2);
  assert.match(html, /<link rel="manifest" href="\/manifest\.webmanifest"\s*\/>/);
});
