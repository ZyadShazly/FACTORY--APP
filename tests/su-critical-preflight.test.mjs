import test from "node:test";
import assert from "node:assert/strict";
import {runCriticalMutation} from "../src/v22/mutations.js";

test("critical mutation denies risky operation before sending changes", async()=>{
 let calls=0;
 const result=await runCriticalMutation({scope:"su-block-test",preflight:async()=>({allowed:false,guidance:"Linked records"}),mutate:async()=>{calls++;return {data:{ok:true}}}});
 assert.equal(calls,0);assert.equal(result.mutationSaved,false);assert.match(result.error.message,/Linked records/);
});
test("critical mutation rejects preflight error and preserves data",async()=>{
 let calls=0;
 const result=await runCriticalMutation({scope:"su-error-test",preflight:async()=>{throw Error("preflight unavailable")},mutate:async()=>{calls++}});
 assert.equal(calls,0);assert.match(result.error.message,/unavailable/);
});
test("critical mutation remains backward compatible",async()=>{
 let calls=0;
 const result=await runCriticalMutation({scope:"su-compat-test",mutate:async()=>{calls++;return {data:{id:"ok"}}},refetch:async()=>({data:[]})});
 assert.equal(calls,1);assert.equal(result.mutationSaved,true);
});
