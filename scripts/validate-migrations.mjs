import fs from "node:fs";
import path from "node:path";

const migrationDirectory = path.resolve("supabase/migrations");
const migrationPattern = /^(\d{14})_([a-z0-9_]+)\.sql$/;
const requiredBaselineTables = [
  "profiles",
  "suppliers",
  "customers",
  "materials",
  "material_purchases",
  "products",
  "production_orders",
  "sales",
  "rentals",
  "supplier_payments",
  "customer_receipts",
  "expenses",
];

const files = fs.readdirSync(migrationDirectory)
  .filter((file) => file.endsWith(".sql"))
  .sort();

const failures = [];
const versions = new Map();

for (const file of files) {
  const match = migrationPattern.exec(file);
  if (!match) {
    failures.push(`${file}: expected <14-digit timestamp>_<snake_case>.sql`);
    continue;
  }
  const [, version] = match;
  if (versions.has(version)) {
    failures.push(`${file}: duplicate version also used by ${versions.get(version)}`);
  } else {
    versions.set(version, file);
  }
}

const baselineName = "20260711165136_legacy_erp_baseline.sql";
if (files[0] !== baselineName) {
  failures.push(`migration chain must start with ${baselineName}`);
} else {
  const baseline = fs.readFileSync(path.join(migrationDirectory, baselineName), "utf8");
  for (const table of requiredBaselineTables) {
    if (!new RegExp(`create\\s+table\\s+public\\.${table}\\s*\\(`, "i").test(baseline)) {
      failures.push(`${baselineName}: missing canonical public.${table} definition`);
    }
    if (!new RegExp(`['\"]${table}['\"]`, "i").test(baseline)) {
      failures.push(`${baselineName}: public.${table} is missing from the RLS/grant contract`);
    }
  }
  for (const contract of [
    /products[\s\S]*item_type\s+text/i,
    /production_orders[\s\S]*waste_percentage\s+numeric/i,
    /alter\s+table\s+public\.%I\s+enable\s+row\s+level\s+security/i,
    /revoke\s+all\s+on\s+table\s+public\.%I\s+from\s+anon,\s*authenticated/i,
  ]) {
    if (!contract.test(baseline)) {
      failures.push(`${baselineName}: missing baseline security/application contract ${contract}`);
    }
  }
  if (/\binsert\s+into\s+public\./i.test(baseline)) {
    failures.push(`${baselineName}: baseline must not copy or invent application data`);
  }
}

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}

console.log(`Validated ${files.length} migrations: canonical names, unique versions, and baseline contract.`);
