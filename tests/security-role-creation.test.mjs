import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createClient } from "@supabase/supabase-js";

const migrationUrl = new URL("../supabase/migrations/202607150002_enforce_protected_role_creation.sql", import.meta.url);
const schemaUrl = new URL("../schema.sql", import.meta.url);

test("migration rejects protected roles during self-service profile creation", async () => {
  const sql = await readFile(migrationUrl, "utf8");

  assert.match(sql, /new\.role not in \('accountant', 'production'\)/);
  assert.match(sql, /auth\.uid\(\) = id[\s\S]*role in \('accountant', 'production'\)/);
  assert.match(sql, /before insert or update of role on public\.profiles/);
  assert.match(sql, /errcode = '42501'/);
  assert.match(sql, /coalesce\(permissions, '\{\}'::jsonb\) = '\{\}'::jsonb/);
});

test("database guard blocks self role changes and reserves administration", async () => {
  const sql = await readFile(migrationUrl, "utf8");

  assert.match(sql, /auth\.role\(\) = 'service_role'/);
  assert.match(sql, /actor_id = old\.id/);
  assert.match(sql, /actor_app_role is distinct from 'manager'/);
  assert.match(sql, /Users cannot change their own role/);
});

test("baseline schema also restricts direct profile inserts", async () => {
  const sql = await readFile(schemaUrl, "utf8");

  assert.match(sql, /profiles_insert_own[\s\S]*role in \('accountant','production'\)/);
  assert.match(sql, /create trigger enforce_profile_role_security/);
});

const liveConfig = {
  url: process.env.SUPABASE_SECURITY_TEST_URL,
  anonKey: process.env.SUPABASE_SECURITY_TEST_ANON_KEY,
  serviceRoleKey: process.env.SUPABASE_SECURITY_TEST_SERVICE_ROLE_KEY,
  confirmed: process.env.SUPABASE_SECURITY_TEST_CONFIRM === "true",
};
const liveEnabled = liveConfig.confirmed && liveConfig.url && liveConfig.anonKey && liveConfig.serviceRoleKey;

test("direct REST API cannot create manager or change the caller's role", { skip: !liveEnabled }, async () => {
  const suffix = `${Date.now()}-${randomUUID()}`;
  const email = `codex-role-hotfix-${suffix}@example.com`;
  const password = `Nx!${randomUUID()}aA9`;
  const admin = createClient(liveConfig.url, liveConfig.serviceRoleKey, { auth: { persistSession: false } });
  const client = createClient(liveConfig.url, liveConfig.anonKey, { auth: { persistSession: false } });
  let userId;

  try {
    const { data: created, error: createError } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
    assert.equal(createError, null);
    userId = created.user.id;

    const { data: signedIn, error: signInError } = await client.auth.signInWithPassword({ email, password });
    assert.equal(signInError, null);
    const token = signedIn.session.access_token;
    const headers = {
      apikey: liveConfig.anonKey,
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      prefer: "return=minimal",
    };

    const protectedInsert = await fetch(`${liveConfig.url}/rest/v1/profiles`, {
      method: "POST",
      headers,
      body: JSON.stringify({ id: userId, full_name: "Security Test", email, role: "manager" }),
    });
    assert.equal(protectedInsert.ok, false, "a crafted manager profile insert must fail");
    assert.ok([400, 401, 403].includes(protectedInsert.status));

    const allowedInsert = await fetch(`${liveConfig.url}/rest/v1/profiles`, {
      method: "POST",
      headers,
      body: JSON.stringify({ id: userId, full_name: "Security Test", email, role: "production" }),
    });
    assert.equal(allowedInsert.ok, true, await allowedInsert.text());

    const selfPromotion = await fetch(`${liveConfig.url}/rest/v1/profiles?id=eq.${encodeURIComponent(userId)}`, {
      method: "PATCH",
      headers,
      body: JSON.stringify({ role: "manager" }),
    });
    assert.equal(selfPromotion.ok, false, "a direct self-promotion request must fail");
    assert.ok([400, 401, 403].includes(selfPromotion.status));
  } finally {
    if (userId) {
      const { error: cleanupError } = await admin.auth.admin.deleteUser(userId);
      assert.equal(cleanupError, null, "the temporary Auth user must be deleted");
    }
  }
});
