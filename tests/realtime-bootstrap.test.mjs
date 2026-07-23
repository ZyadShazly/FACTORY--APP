import assert from "node:assert/strict";
import test from "node:test";

import {
  applyRealtimePayload,
  buildRealtimeChannelPlan,
  nextRealtimeState,
  realtimeTablesForKeys,
} from "../src/app/realtimeBootstrap.js";

test("realtime table planning includes only requested data keys", () => {
  const entries = realtimeTablesForKeys(["projects", "employees", "assetRealtimeSignal"]);
  assert.deepEqual(entries, [
    { table: "projects", key: "projects" },
    { table: "employees", key: "employees" },
    { table: "asset_realtime_signal", key: "assetRealtimeSignal" },
  ]);
});

test("channel plans are deterministic and can exclude signal tables", () => {
  const plan = buildRealtimeChannelPlan({
    role: "accountant",
    dataKeys: ["projects", "employees", "projectRealtimeSignal"],
    includeSignals: false,
  });

  assert.deepEqual(plan, [
    {
      id: "accountant:projects",
      table: "projects",
      key: "projects",
      schema: "public",
      event: "*",
    },
    {
      id: "accountant:employees",
      table: "employees",
      key: "employees",
      schema: "public",
      event: "*",
    },
  ]);
});

test("realtime connection status preserves existing semantics", () => {
  assert.equal(nextRealtimeState({ a: "SUBSCRIBED", b: "SUBSCRIBED" }), "CONNECTED");
  assert.equal(nextRealtimeState({ a: "CHANNEL_ERROR" }), "RECONNECTING");
  assert.equal(nextRealtimeState({ a: "TIMED_OUT" }), "RECONNECTING");
  assert.equal(nextRealtimeState({ a: "CLOSED" }), "CONNECTING");
});

test("realtime payload application is immutable and idempotent", () => {
  const initial = { projects: [{ id: "1", name: "Old" }] };
  const inserted = applyRealtimePayload(initial, { eventType: "INSERT", new: { id: "2", name: "New" } }, "projects");
  assert.deepEqual(inserted.projects, [{ id: "1", name: "Old" }, { id: "2", name: "New" }]);
  assert.notEqual(inserted, initial);

  const updated = applyRealtimePayload(inserted, { eventType: "UPDATE", new: { id: "2", name: "Updated" } }, "projects");
  assert.deepEqual(updated.projects[1], { id: "2", name: "Updated" });

  const deleted = applyRealtimePayload(updated, { eventType: "DELETE", old: { id: "1" } }, "projects");
  assert.deepEqual(deleted.projects, [{ id: "2", name: "Updated" }]);

  assert.equal(applyRealtimePayload(deleted, { eventType: "UPDATE", new: {} }, "projects"), deleted);
});
