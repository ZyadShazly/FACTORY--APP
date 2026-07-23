import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const source = fs.readFileSync("src/AppMonolith.jsx", "utf8");

test("AppMonolith consumes extracted data bootstrap", () => {
  assert.match(source, /createTableFetcher, EMPTY_DATA/);
  assert.match(source, /const fetchTableRows = createTableFetcher\(\{/);
  assert.match(source, /projectFilesTable: TABLES\.projectFiles/);
  assert.doesNotMatch(source, /const EMPTY_DATA = \{/);
  assert.doesNotMatch(source, /async function fetchTableRows\(key, table\)/);
  assert.doesNotMatch(source, /PROJECT_FILES_TABLE/);
});

test("AppMonolith consumes extracted realtime helpers", () => {
  assert.match(source, /buildRealtimeChannelPlan, nextRealtimeState/);
  assert.match(source, /nextRealtimeState\(channelStatuses\)/);
  assert.match(source, /buildRealtimeChannelPlan\(\{/);
  assert.doesNotMatch(source, /combinedRealtimeStatus\(channelStatuses\)/);
  assert.doesNotMatch(source, /Object\.entries\(REALTIME_TABLE_TO_KEY\)/);
  assert.doesNotMatch(source, /REALTIME_TABLE_TO_KEY/);
});
