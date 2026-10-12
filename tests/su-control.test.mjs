import test from "node:test";
import assert from "node:assert/strict";
import {isSuProfile,evaluateSuImpact,describeSuImpact} from "../src/app/suControl.js";

test("UI SU recognition requires matching UUID and active owner",()=>{
 const user={id:"su-uuid",role:"owner",status:"active",email:"su@nextep.local"};
 assert.equal(isSuProfile(user,"su-uuid"),true);
 assert.equal(isSuProfile({...user,id:"other-owner"},"su-uuid"),false);
 assert.equal(isSuProfile({...user,status:"inactive"},"su-uuid"),false);
 assert.equal(isSuProfile({...user,role:"manager"},"su-uuid"),false);
 assert.equal(isSuProfile(user,undefined),false);
});
test("shows before/after changes without mutating inputs",()=>{
 const before={name:"Old",quantity:4};const after={name:"New",quantity:4};
 const result=evaluateSuImpact({module:"assets",action:"update",before,after});
 assert.deepEqual(result.changes,[{field:"name",before:"Old",after:"New"}]);
 assert.equal(result.risk,"low");assert.equal(result.allowed,true);
 assert.match(describeSuImpact(result),/Old/);
 assert.equal(before.name,"Old");
});
test("blocks unsafe deletion with linked records",()=>{
 const result=evaluateSuImpact({module:"accounting",action:"delete",dependencies:[{label:"posted entries",count:2,immutable:true}]});
 assert.equal(result.risk,"blocked");assert.equal(result.allowed,false);
});
test("flags financial links high risk without granting server access",()=>{
 const result=evaluateSuImpact({module:"sales",action:"update",before:{total:1},after:{total:2},dependencies:[{label:"AR",count:1,financial:true}]});
 assert.equal(result.risk,"high");assert.equal(result.allowed,true);
});
