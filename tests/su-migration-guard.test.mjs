import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const sql=fs.readFileSync(path.join("supabase","migrations","20261012000000_su_asset_administration.sql"),"utf8");
test("SU SQL function bodies all use balanced dollar quoting",()=>{
 const delimiters=[...sql.matchAll(/\$\$/g)];
 assert.equal(delimiters.length%2,0,"Unbalanced $$ delimiters");
 assert.doesNotMatch(sql,/\bas \$\s*\nbegin\b/i);
 assert.doesNotMatch(sql,/\bend \$\s*;/i);
});
test("SU migration does not overwrite unrelated tables or clear data",()=>{
 assert.doesNotMatch(sql,/\b(drop\s+table|truncate\s+|delete\s+from\s+public\.(?!asset_movements\b|assets\b))/i);
 assert.match(sql,/can_su_admin_assets\(\)/);
 assert.match(sql,/auth\.uid\(\)/);
});
test("Existing asset balance updates remain protected by ledger",()=>{
 assert.match(sql,/app\.asset_balance_update/);
 assert.match(sql,/Cached balances may only be changed by ledger movements/);
});

test("SU migration preserves maintenance workflow protection in all integrity definitions",()=>{
 const implementations=sql.match(/create or replace function public\.protect_asset_integrity\(\)[\s\S]*?end \$\$;/g)||[];
 assert.equal(implementations.length,2);
 for(const implementation of implementations){
   assert.match(implementation,/app\.asset_maintenance_rpc/);
   assert.match(implementation,/Maintenance status may only change through the maintenance workflow/);
   assert.match(implementation,/app\.asset_balance_update/);
 }
});

test("SU metadata-and-quantity correction runs atomically in one RPC",()=>{
 assert.match(sql,/perform public\.adjust_asset_quantity\(a\.id,next_qty-a\.total_quantity,reason\)/);
 assert.match(sql,/next_tracking<>'quantity'/);
 const ui=fs.readFileSync(path.join("src","assets","AssetsPage.jsx"),"utf8");
 assert.match(ui,/rpc\("su_update_asset_details"/);
 const start=ui.indexOf("async function saveAsset");
 const end=ui.indexOf("function suAssetImpact",start);
 const save=ui.slice(start,end);
 assert.doesNotMatch(save,/rpc\("adjust_asset_quantity"/,"SU save must not perform a second, non-atomic RPC");
});

test("SU metadata RPC cannot bypass stock status or location movement workflow",()=>{
 assert.match(sql,/Operational status requires its dedicated movement workflow/);
 assert.match(sql,/Location changes require the asset transfer workflow/);
 assert.match(sql,/operational_status=a\.operational_status/);
 assert.match(sql,/current_location_id=a\.current_location_id/);
 const ui=fs.readFileSync(path.join("src","assets","AssetsPage.jsx"),"utf8");
 assert.match(ui,/<Select disabled=\{editing\} value=\{form\.operational_status\}/);
 assert.match(ui,/<Select disabled=\{editing\} value=\{form\.current_location_id\}/);
});
