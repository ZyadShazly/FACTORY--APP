import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const settings=fs.readFileSync("src/settings/SettingsPage.jsx","utf8");
const migration=fs.readFileSync("supabase/migrations/20260719185315_system_ux_hardening.sql","utf8");

test("currency mutation is only offered to the Owner allowed by the server",()=>{
  assert.match(settings,/canManageCurrency = currentProfile\?\.role === "owner"/);
  assert.match(settings,/canManageCurrency \? <form onSubmit=\{saveCurrency\}/);
  assert.match(settings,/تغيير إعداد مالي عام متاح لمالك النظام فقط/);
  assert.match(migration,/role='owner' and status='active'/);
});

test("manager still retains the protected account recovery workflow",()=>{
  assert.match(settings,/onSubmit=\{repairAccount\}/);
  assert.match(settings,/Recovery can only create accountant or production profiles|الدور الآمن/);
});
