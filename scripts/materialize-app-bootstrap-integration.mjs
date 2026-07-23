import fs from "node:fs";

const appPath = "src/AppMonolith.jsx";
let source = fs.readFileSync(appPath, "utf8");

function replaceRequired(pattern, replacement, label, transformedPattern) {
  if (transformedPattern?.test(source)) return;
  if (!pattern.test(source)) throw new Error(`Missing expected source block: ${label}`);
  source = source.replace(pattern, replacement);
}

replaceRequired(
  /import \{ PROJECT_FILES_TABLE \} from "\.\/v22\/fileTypes";\r?\n/,
  "",
  "legacy project files table import",
  /projectFilesTable: TABLES\.projectFiles/,
);

replaceRequired(
  /import \{ combinedRealtimeStatus, dataTableKeysForRole, REALTIME_TABLE_TO_KEY, resolveAllowedTab, TABLES \} from "\.\/realtime";\r?\n/,
  'import { dataTableKeysForRole, resolveAllowedTab, TABLES } from "./realtime";\n',
  "legacy realtime imports",
  /import \{ dataTableKeysForRole, resolveAllowedTab, TABLES \} from "\.\/realtime";/,
);

replaceRequired(
  /import \{ withTimeout \} from "\.\/bootstrap";\r?\n/,
  'import { withTimeout } from "./bootstrap";\nimport { createTableFetcher, EMPTY_DATA } from "./app/dataBootstrap";\nimport { buildRealtimeChannelPlan, nextRealtimeState } from "./app/realtimeBootstrap";\n',
  "bootstrap import boundary",
  /createTableFetcher, EMPTY_DATA/,
);

replaceRequired(
  /\r?\nconst EMPTY_DATA = \{[\s\S]*?\r?\n\};\r?\nconst PAGE_DESCRIPTIONS = \{/,
  "\nconst PAGE_DESCRIPTIONS = {",
  "local EMPTY_DATA",
  /createTableFetcher, EMPTY_DATA/,
);

replaceRequired(
  /\r?\nasync function fetchTableRows\(key, table\) \{[\s\S]*?\r?\n\}\r?\n\r?\n\/\* ------------------------------ دوال الحسابات ------------------------------ \*\//,
  `\nconst fetchTableRows = createTableFetcher({\n  supabase,\n  withTimeout,\n  projectFilesTable: TABLES.projectFiles,\n  pageLabels: PAGE_LABELS,\n  logger: console,\n});\n\n/* ------------------------------ دوال الحسابات ------------------------------ */`,
  "local fetchTableRows",
  /const fetchTableRows = createTableFetcher\(\{/,
);

replaceRequired(
  /const\s+combined\s*=\s*combinedRealtimeStatus\s*\(\s*channelStatuses\s*\)\s*;/,
  "const combined = nextRealtimeState(channelStatuses);",
  "combined realtime status call",
  /const\s+combined\s*=\s*nextRealtimeState\s*\(\s*channelStatuses\s*\)\s*;/,
);

replaceRequired(
  /Object\.entries\(REALTIME_TABLE_TO_KEY\)\.filter\(\(\[, key\]\) => activeTableKeys\.includes\(key\) \|\| \(key === "assetRealtimeSignal" && activeTableKeys\.includes\("assets"\)\) \|\| \(key === "projectRealtimeSignal" && activeTableKeys\.includes\("projects"\)\)\)\.forEach\(\(\[table, key\]\) => \{\r?\n\s*dataChannel\.on\("postgres_changes", \{ event: "\*", schema: "public", table \},/,
  `buildRealtimeChannelPlan({\n        role: profile.role,\n        dataKeys: [\n          ...activeTableKeys,\n          ...(activeTableKeys.includes("assets") ? ["assetRealtimeSignal"] : []),\n          ...(activeTableKeys.includes("projects") ? ["projectRealtimeSignal"] : []),\n        ],\n      }).forEach(({ table, key, event, schema }) => {\n        dataChannel.on("postgres_changes", { event, schema, table },`,
  "realtime channel planning",
  /buildRealtimeChannelPlan\(\{/,
);

for (const forbidden of [
  "const EMPTY_DATA = {",
  "async function fetchTableRows(key, table)",
  "combinedRealtimeStatus(channelStatuses)",
  "Object.entries(REALTIME_TABLE_TO_KEY)",
]) {
  if (source.includes(forbidden)) throw new Error(`Legacy source remains: ${forbidden}`);
}

fs.writeFileSync(appPath, source);

const testPath = "tests/app-bootstrap-integration.test.mjs";
fs.writeFileSync(testPath, `import assert from "node:assert/strict";\nimport fs from "node:fs";\nimport test from "node:test";\n\nconst source = fs.readFileSync("src/AppMonolith.jsx", "utf8");\n\ntest("AppMonolith consumes extracted data bootstrap", () => {\n  assert.match(source, /createTableFetcher, EMPTY_DATA/);\n  assert.match(source, /const fetchTableRows = createTableFetcher\\(\\{/);\n  assert.doesNotMatch(source, /const EMPTY_DATA = \\{/);\n  assert.doesNotMatch(source, /async function fetchTableRows\\(key, table\\)/);\n});\n\ntest("AppMonolith consumes extracted realtime helpers", () => {\n  assert.match(source, /buildRealtimeChannelPlan, nextRealtimeState/);\n  assert.match(source, /nextRealtimeState\\(channelStatuses\\)/);\n  assert.match(source, /buildRealtimeChannelPlan\\(\\{/);\n  assert.doesNotMatch(source, /combinedRealtimeStatus\\(channelStatuses\\)/);\n  assert.doesNotMatch(source, /Object\\.entries\\(REALTIME_TABLE_TO_KEY\\)/);\n});\n`);

console.log("Materialized AppMonolith bootstrap integration.");
