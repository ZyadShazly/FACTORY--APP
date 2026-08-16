import test from "node:test";
import assert from "node:assert/strict";
import { runCriticalMutation, syncMutation } from "../src/v22/mutations.js";
import fs from "node:fs";

test("UAT-007/UAT-013 keeps mutation success distinct from refresh failure", async () => {
  const result = await syncMutation({ scope:"test", mutationResult:{data:{id:"1"},error:null}, refetch:async()=>({error:new Error("offline")}) });
  assert.equal(result.error,null);
  assert.equal(result.mutationSaved,true);
  assert.equal(result.refreshError.message,"offline");
});

test("operation feedback is transient and distinguishes warning state",()=>{
  const shared=fs.readFileSync("src/v22/shared.jsx","utf8");
  const app=fs.readFileSync("src/AppMonolith.jsx","utf8");
  assert.match(shared,/window\.setTimeout\(onDismiss/);
  assert.match(app,/operationFeedbackType = \(message\).*"warning" : "success"/);
  assert.match(app,/Banner type=\{operationFeedbackType\(ok\)\}/);
});

test("critical mutations verify final server state and bound refresh", async()=>{
  const result=await runCriticalMutation({scope:"cancel",mutate:async()=>({data:{status:"cancelled"},error:null}),verify:async(row)=>row.data.status==="cancelled",refetch:async()=>({data:[],error:null})});
  assert.equal(result.error,null);
  assert.equal(result.mutationSaved,true);
  assert.equal(result.verificationResult,true);
});

test("critical mutations suppress concurrent duplicate submits for the same scope", async()=>{
  let mutationCalls=0;
  let release;
  const gate=new Promise((resolve)=>{release=resolve;});
  const options={
    scope:"sales:post",
    mutate:async()=>{mutationCalls+=1;await gate;return {data:{id:"sale-1"},error:null};},
    verify:async()=>true,
    refetch:async()=>({data:[],error:null}),
  };
  const first=runCriticalMutation(options);
  const second=runCriticalMutation(options);
  assert.equal(first,second);
  assert.equal(mutationCalls,0);
  await Promise.resolve();
  assert.equal(mutationCalls,1);
  release();
  const [firstResult,secondResult]=await Promise.all([first,second]);
  assert.equal(mutationCalls,1);
  assert.equal(firstResult.error,null);
  assert.equal(secondResult.error,null);
});
