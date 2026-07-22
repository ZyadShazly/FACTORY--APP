import assert from "node:assert/strict";
import test from "node:test";

import { createTableFetcher, EMPTY_DATA } from "../src/app/dataBootstrap.js";

function query(result) {
  return {
    select() { return this; },
    order() { return Promise.resolve(result); },
  };
}

function harness({ rpcResults = {}, tableResults = {} } = {}) {
  const calls = [];
  const logs = [];
  const supabase = {
    rpc(name) {
      calls.push(["rpc", name]);
      return Promise.resolve(rpcResults[name] ?? { data: [], error: null });
    },
    from(table) {
      calls.push(["from", table]);
      const results = tableResults[table] || [{ data: [], error: null }];
      const result = Array.isArray(results) ? results.shift() : results;
      return query(result);
    },
  };
  const withTimeout = async (promise, _timeout, label) => {
    calls.push(["timeout", label || null]);
    return promise;
  };
  const logger = {
    warn: (...args) => logs.push(["warn", ...args]),
    info: (...args) => logs.push(["info", ...args]),
    error: (...args) => logs.push(["error", ...args]),
  };
  return {
    calls,
    logs,
    fetchTableRows: createTableFetcher({
      supabase,
      withTimeout,
      projectFilesTable: "project_files",
      pageLabels: { projects: "المشاريع" },
      logger,
    }),
  };
}

test("empty data contract keeps every major module collection", () => {
  for (const key of [
    "projects", "projectFiles", "materials", "productionOrders", "assets",
    "employees", "payroll", "dailyLabor", "auditLog", "workSchedules",
  ]) {
    assert.ok(Array.isArray(EMPTY_DATA[key]), key);
  }
  assert.equal(Object.isFrozen(EMPTY_DATA), true);
});

test("protected business datasets route through their visible RPCs", async () => {
  const { fetchTableRows, calls } = harness();
  const expected = {
    projects: "get_projects_visible",
    productionOrders: "get_production_orders_visible",
    assets: "get_assets_visible",
    payroll: "get_payroll_visible",
    assetAlerts: "get_asset_alerts_visible",
  };

  for (const [key, rpc] of Object.entries(expected)) {
    await fetchTableRows(key, key);
    assert.ok(calls.some((call) => call[0] === "rpc" && call[1] === rpc), `${key}:${rpc}`);
  }
  assert.ok(calls.some((call) => call[0] === "timeout" && call[1]?.includes("المشاريع")));
});

test("audit log falls back to legacy rows when actor relation is unavailable", async () => {
  const relationError = { code: "PGRST200" };
  const { fetchTableRows, calls, logs } = harness({
    tableResults: {
      audit_log: [
        { data: null, error: relationError },
        { data: [{ id: 1 }], error: null },
      ],
    },
  });

  const result = await fetchTableRows("auditLog", "audit_log");
  assert.deepEqual(result.data, [{ id: 1 }]);
  assert.equal(calls.filter((call) => call[0] === "from" && call[1] === "audit_log").length, 2);
  assert.ok(logs.some((log) => log[0] === "warn" && String(log[1]).includes("AuditLog")));
});

test("project files fall back to uploaded_at only for missing created_at", async () => {
  const { fetchTableRows, calls, logs } = harness({
    tableResults: {
      project_files: [
        { data: null, error: { code: "42703" } },
        { data: [{ id: "file-1" }], error: null },
      ],
    },
  });

  const result = await fetchTableRows("projectFiles", "project_files");
  assert.deepEqual(result.data, [{ id: "file-1" }]);
  assert.equal(calls.filter((call) => call[0] === "from" && call[1] === "project_files").length, 2);
  assert.ok(logs.some((log) => log[0] === "info" && String(log[1]).includes("ProjectFiles")));
});

test("unexpected loader exceptions become stable error results", async () => {
  const expected = new Error("network down");
  const supabase = {
    rpc() { throw expected; },
    from() { throw expected; },
  };
  const fetchTableRows = createTableFetcher({
    supabase,
    withTimeout: async (promise) => promise,
    projectFilesTable: "project_files",
    logger: { error() {} },
  });

  const result = await fetchTableRows("projects", "projects");
  assert.equal(result.data, null);
  assert.equal(result.error, expected);
});
