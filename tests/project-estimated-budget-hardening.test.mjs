import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const preflight = await readFile(new URL("../supabase/migrations/2026071900029_project_estimated_budget_preflight.sql", import.meta.url), "utf8");
const hardening = await readFile(new URL("../supabase/migrations/202607190004_project_estimated_budget_security_accounting_hardening.sql", import.meta.url), "utf8");

test("legacy project costs use their own IDs before migration 003 indexes are created", () => {
  assert.match(preflight, /when coalesce\(source_type, 'legacy'\) = 'legacy' then id/);
  assert.match(preflight, /source_reference_key = coalesce\(source_reference_key, 'legacy:project_costs:' \|\| id::text\)/);
});

test("legacy rows are excluded from canonical source revision uniqueness", () => {
  assert.match(hardening, /project_costs_source_revision_unique[\s\S]*where source_type <> 'legacy'/);
});

test("non-financial reads hide section totals and waste percentages", () => {
  assert.match(hardening, /to_jsonb\(s\) - 'subtotal'/);
  assert.match(hardening, /'unit_cost','estimated_cost','waste_percentage','waste_amount','total_with_waste'/);
});

test("non-financial comparisons hide all cost, waste, and variance inputs", () => {
  assert.match(hardening, /'old_unit_cost','new_unit_cost','old_waste_percentage','new_waste_percentage'/);
  assert.match(hardening, /'old_amount','new_amount'/);
  assert.match(hardening, /'variance_amount', case when can_finance then/);
});

test("budget approval updates expected cost but never project revenue", () => {
  const approve = hardening.slice(
    hardening.indexOf("create or replace function public.approve_project_budget"),
    hardening.indexOf("create or replace function public.get_project_budget_visible"),
  );
  assert.match(approve, /set expected_cost = v\.expected_total_cost/);
  assert.doesNotMatch(approve, /revenue\s*=|set[^;]*target_sale_price/);
});

test("hardening keeps fixed search paths and explicit API grants", () => {
  for (const signature of [
    "approve_project_budget(uuid)",
    "get_project_budget_visible(uuid,uuid)",
    "compare_project_budget_versions(uuid,uuid)",
  ]) {
    assert.match(hardening, new RegExp(`grant execute on function public\\.${signature.replace(/[()]/g, "\\$&")} to authenticated`));
  }
  const functions = [...hardening.matchAll(/create or replace function public\.[\s\S]*?\n\$\$;/g)].map((match) => match[0]);
  assert.equal(functions.length, 3);
  for (const fn of functions) assert.match(fn, /set search_path = public, private, pg_temp/);
});
