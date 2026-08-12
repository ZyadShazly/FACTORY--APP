import { createClient } from "npm:@supabase/supabase-js@2.110.2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, payload: Record<string, unknown>) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizePhone(value: unknown) {
  const compact = String(value || "").trim().replace(/[^0-9+]/g, "");
  const international = compact.startsWith("00") ? `+${compact.slice(2)}` : compact;
  return /^\+[1-9][0-9]{7,14}$/.test(international) ? international : "";
}

function mayManage(actorRole: string, targetRole: string) {
  return actorRole === "owner" || actorRole === "manager" && ["accountant", "production"].includes(targetRole);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return reply(405, { ok: false, error: "Method not allowed" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const publicKey = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SECRET_KEY");
  const authorization = request.headers.get("Authorization");
  if (!supabaseUrl || !publicKey || !serviceKey) return reply(500, { ok: false, error: "Function environment is incomplete" });
  if (!authorization?.startsWith("Bearer ")) return reply(401, { ok: false, error: "Authentication is required" });

  const caller = createClient(supabaseUrl, publicKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const token = authorization.slice("Bearer ".length);
  const { data: identity, error: identityError } = await caller.auth.getUser(token);
  if (identityError || !identity.user) return reply(401, { ok: false, error: "Invalid authentication session" });

  const { data: actor, error: actorError } = await caller.from("profiles").select("id,role,status,must_change_password").eq("id", identity.user.id).maybeSingle();
  if (actorError || !actor || actor.status !== "active") return reply(403, { ok: false, error: "Active application account required" });

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return reply(400, { ok: false, error: "Invalid JSON payload" });
  }

  if (body.action === "change_password") {
    const newPassword = String(body.new_password || "");
    if (!actor.must_change_password) return reply(409, { ok: false, error: "The temporary password was already changed" });
    if (newPassword.length < 10) return reply(400, { ok: false, error: "The new password must contain at least 10 characters" });
    const { error: passwordError } = await admin.auth.admin.updateUserById(identity.user.id, { password: newPassword });
    if (passwordError) return reply(400, { ok: false, error: passwordError.message });
    const { error: completionError } = await admin.rpc("complete_managed_password_change", { target_user_id: identity.user.id });
    if (completionError) return reply(500, { ok: false, error: "Password changed but account activation could not be completed; contact the system owner" });
    return reply(200, { ok: true });
  }

  if (!["owner", "manager"].includes(actor.role)) {
    return reply(403, { ok: false, error: "Active owner or manager authorization required" });
  }

  if (body.action === "create") {
    const fullName = String(body.full_name || "").trim();
    const phone = normalizePhone(body.phone);
    const temporaryPassword = String(body.temporary_password || "");
    const role = String(body.role || "");
    if (!fullName || !phone || temporaryPassword.length < 10 || !mayManage(actor.role, role)) {
      return reply(400, { ok: false, error: "Invalid account name, phone, temporary password or role" });
    }

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      phone,
      password: temporaryPassword,
      phone_confirm: true,
      user_metadata: { full_name: fullName, managed_account: true },
    });
    if (createError || !created.user) return reply(400, { ok: false, error: createError?.message || "Authentication account creation failed" });

    let authUser = created.user;
    if (normalizePhone(authUser.phone) !== phone) {
      const { data: updated, error: authPhoneError } = await admin.auth.admin.updateUserById(created.user.id, {
        phone,
        phone_confirm: true,
      });
      if (authPhoneError || !updated.user) {
        const rollback = await admin.auth.admin.deleteUser(created.user.id);
        return reply(400, {
          ok: false,
          error: authPhoneError?.message || "Authentication phone could not be persisted",
          rolled_back: !rollback.error,
        });
      }
      authUser = updated.user;
    }

    const { data: confirmedAuth, error: confirmError } = await admin.auth.admin.getUserById(created.user.id);
    const confirmedPhone = normalizePhone(confirmedAuth.user?.phone);
    if (confirmError || !confirmedAuth.user || confirmedPhone !== phone) {
      const rollback = await admin.auth.admin.deleteUser(created.user.id);
      return reply(400, {
        ok: false,
        error: "Authentication phone could not be confirmed after account creation",
        rolled_back: !rollback.error,
      });
    }

    const { data: profile, error: profileError } = await caller.rpc("admin_register_managed_profile", {
      target_user_id: authUser.id,
      target_full_name: fullName,
      target_phone: confirmedPhone,
      target_role: role,
    });
    if (profileError) {
      const rollback = await admin.auth.admin.deleteUser(created.user.id);
      if (rollback.error) console.error("managed account rollback failed", { userId: created.user.id, error: rollback.error.message });
      return reply(400, { ok: false, error: profileError.message, rolled_back: !rollback.error });
    }
    return reply(201, { ok: true, profile: { id: profile.id, full_name: profile.full_name, phone: profile.phone, role: profile.role, status: profile.status } });
  }

  if (body.action === "update_phone") {
    const userId = String(body.user_id || "");
    const phone = normalizePhone(body.phone);
    const reason = String(body.reason || "").trim();
    if (!userId || !phone || !reason || userId === identity.user.id) return reply(400, { ok: false, error: "Invalid phone change request" });

    const { data: target, error: targetError } = await caller.from("profiles").select("id,role").eq("id", userId).maybeSingle();
    if (targetError || !target) return reply(404, { ok: false, error: "Target account not found" });
    if (!mayManage(actor.role, target.role)) return reply(403, { ok: false, error: "Your role cannot change this account phone" });

    const { data: previousAuth, error: previousError } = await admin.auth.admin.getUserById(userId);
    if (previousError || !previousAuth.user) return reply(404, { ok: false, error: "Authentication account not found" });
    const oldPhone = previousAuth.user.phone || "";
    const { error: authUpdateError } = await admin.auth.admin.updateUserById(userId, { phone, phone_confirm: true });
    if (authUpdateError) return reply(400, { ok: false, error: authUpdateError.message });

    const { data: profile, error: profileError } = await caller.rpc("admin_update_managed_phone", {
      target_user_id: userId,
      target_phone: phone,
      reason,
    });
    if (profileError) {
      const rollback = oldPhone ? await admin.auth.admin.updateUserById(userId, { phone: oldPhone, phone_confirm: true }) : null;
      if (rollback?.error) console.error("managed phone rollback failed", { userId, error: rollback.error.message });
      return reply(400, { ok: false, error: profileError.message, rolled_back: Boolean(oldPhone && !rollback?.error) });
    }
    return reply(200, { ok: true, profile: { id: profile.id, phone: profile.phone } });
  }

  return reply(400, { ok: false, error: "Unsupported action" });
});
