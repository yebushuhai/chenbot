import {test} from 'node:test';
import assert from 'node:assert/strict';
import {recognizeForUser} from './recognition.mjs';
const input={accessToken:'token',requestId:'request_1234567890',image:Buffer.from('image'),mimeType:'image/jpeg',language:'en'};
function adapters(){const calls=[];return {calls, authenticate:async()=>({id:'user-1'}),reserve:async x=>{calls.push(['reserve',x.userId]);return {status:'reserved'}},recognize:async()=>({items:[]}),finish:async x=>calls.push(['finish',x.status])};}
test('failure after reservation triggers a failed finalization',async()=>{const a=adapters();a.recognize=async()=>{throw Error('provider unavailable')};await assert.rejects(recognizeForUser(input,a),/provider unavailable/);assert.deepEqual(a.calls,[['reserve','user-1'],['finish','failed']]);});
test('completed retry reuses prior result without calling model',async()=>{const a=adapters();a.reserve=async()=>({status:'completed',result:{items:['previous']}});a.recognize=async()=>{throw Error('must not call')};assert.deepEqual(await recognizeForUser(input,a),{items:['previous']});});
test('insufficient credit never invokes model',async()=>{const a=adapters();a.reserve=async()=>({status:'insufficient'});a.recognize=async()=>{throw Error('must not call')};await assert.rejects(recognizeForUser(input,a),/Insufficient credits/);});
test('missing auth is rejected before reservation',async()=>{const a=adapters();await assert.rejects(recognizeForUser({...input,accessToken:''},a),/Authentication/);assert.deepEqual(a.calls,[]);});
