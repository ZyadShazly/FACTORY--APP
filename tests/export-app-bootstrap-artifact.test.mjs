import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

function materialize(source) {
  source = source.replace('import { PROJECT_FILES_TABLE } from "./v22/fileTypes";\n', "");
  source = source.replace(
    'import { combinedRealtimeStatus, dataTableKeysForRole, REALTIME_TABLE_TO_KEY, resolveAllowedTab, TABLES } from "./realtime";\n',
    'import { dataTableKeysForRole, resolveAllowedTab, TABLES } from "./realtime";\n',
  );
  source = source.replace(
    'import { withTimeout } from "./bootstrap";\n',
    'import { withTimeout } from "./bootstrap";\nimport { createTableFetcher, EMPTY_DATA } from "./app/dataBootstrap";\nimport { buildRealtimeChannelPlan, nextRealtimeState } from "./app/realtimeBootstrap";\n',
  );
  source = source.replace(/\nconst EMPTY_DATA = \{[\s\S]*?\n\};\nconst PAGE_DESCRIPTIONS = \{/, "\nconst PAGE_DESCRIPTIONS = {");
  source = source.replace(
    /\nasync function fetchTableRows\(key, table\) \{[\s\S]*?\n\}\n\n\/\* ------------------------------ دوال الحسابات ------------------------------ \*\//,
    '\nconst fetchTableRows = createTableFetcher({\n  supabase,\n  withTimeout,\n  projectFilesTable: TABLES.projectFiles,\n  pageLabels: PAGE_LABELS,\n  logger: console,\n});\n\n/* ------------------------------ دوال الحسابات ------------------------------ */',
  );
  source = source.replace("const combined = combinedRealtimeStatus(channelStatuses);", "const combined = nextRealtimeState(channelStatuses);");
  source = source.replace(
    /Object\.entries\(REALTIME_TABLE_TO_KEY\)\.filter\(\(\[, key\]\) => activeTableKeys\.includes\(key\) \|\| \(key === "assetRealtimeSignal" && activeTableKeys\.includes\("assets"\)\) \|\| \(key === "projectRealtimeSignal" && activeTableKeys\.includes\("projects"\)\)\)\.forEach\(\(\[table, key\]\) => \{\n\s*dataChannel\.on\("postgres_changes", \{ event: "\*", schema: "public", table \},/,
    'buildRealtimeChannelPlan({\n        role: profile.role,\n        dataKeys: [\n          ...activeTableKeys,\n          ...(activeTableKeys.includes("assets") ? ["assetRealtimeSignal"] : []),\n          ...(activeTableKeys.includes("projects") ? ["projectRealtimeSignal"] : []),\n        ],\n      }).forEach(({ table, key, event, schema }) => {\n        dataChannel.on("postgres_changes", { event, schema, table },',
  );
  return source;
}

test("export materialized AppMonolith artifact", () => {
  const original = fs.readFileSync("src/AppMonolith.jsx", "utf8");
  const output = materialize(original);
  assert.notEqual(output, original);
  assert.match(output, /createTableFetcher, EMPTY_DATA/);
  assert.match(output, /buildRealtimeChannelPlan, nextRealtimeState/);
  assert.doesNotMatch(output, /const EMPTY_DATA = \{/);
  assert.doesNotMatch(output, /async function fetchTableRows\(key, table\)/);
  assert.doesNotMatch(output, /Object\.entries\(REALTIME_TABLE_TO_KEY\)/);
  console.error("APP_BOOTSTRAP_BASE64_START");
  console.error(Buffer.from(output, "utf8").toString("base64"));
  console.error("APP_BOOTSTRAP_BASE64_END");
  assert.fail("intentional export failure");
});
