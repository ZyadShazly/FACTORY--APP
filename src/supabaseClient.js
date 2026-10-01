import { createClient } from "@supabase/supabase-js";

// fresh-main is intentionally isolated from the current main database.
// These are client-side Supabase credentials (publishable, not service-role).
const url = "https://qxucepnpluwygltfcnsz.supabase.co";
const key = "sb_publishable_wSdvPwLcph0jpXp5soAXEg_ovc2DuDm";

function normalizePhone(value) {
  const compact = String(value || "").trim().replace(/[^0-9+]/g, "");
  const international = compact.startsWith("00") ? `+${compact.slice(2)}` : compact;
  return /^\+[1-9][0-9]{7,14}$/.test(international) ? international : "";
}

export function managedPhoneAuthEmail(value) {
  const phone = normalizePhone(value);
  return phone ? `phone.${phone.slice(1)}@nextep.local` : "";
}

const client = createClient(url, key);
const signInWithPassword = client.auth.signInWithPassword.bind(client.auth);
client.auth.signInWithPassword = (credentials) => {
  if (credentials?.phone && !credentials?.email) {
    const email = managedPhoneAuthEmail(credentials.phone);
    if (!email) return signInWithPassword(credentials);
    return signInWithPassword({ email, password: credentials.password });
  }
  return signInWithPassword(credentials);
};

export const supabase = client;
