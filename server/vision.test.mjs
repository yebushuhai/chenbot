import { test } from 'node:test';
import assert from 'node:assert/strict';
import { recognizeImage, validateResult } from './vision.mjs';
const item = {kind:'object',word:'cat',reading:'',zh:'猫',en_definition:'A small animal.',example:'A cat sleeps.',example_zh:'一只猫在睡觉。',box:[0.1,0.2,0.8,0.9]};
test('rejects impossible boxes and unsafe adjectives', () => {
  assert.throws(() => validateResult({items:[{...item,box:[0.9,0,0.1,1]}]}));
  assert.throws(() => validateResult({items:[{...item,kind:'adjective'}]}));
  assert.throws(() => validateResult({items:[item,{...item,kind:'adjective',box:null}]}));
  assert.deepEqual(validateResult({items:[{...item,kind:'adjective',box:null}]}).items[0].box,null);
});
test('sends valid image and parses provider data', async () => {
  let request;
  const fetchImpl = async (url, options) => { request = {url:String(url), options}; return {ok:true,json:async()=>({choices:[{message:{content:JSON.stringify({items:[item]})}}]})}; };
  const result = await recognizeImage({bytes:Buffer.from([255,216,255,0]),mimeType:'image/jpeg',language:'en',apiKey:'test',baseUrl:'https://example.com/v1',fetchImpl});
  assert.equal(result.items[0].word,'cat'); assert.equal(request.url,'https://example.com/v1/chat/completions');
});
test('rejects malformed images before calling provider', async () => {
  await assert.rejects(recognizeImage({bytes:Buffer.from('bad'),mimeType:'image/jpeg',language:'en',apiKey:'test',baseUrl:'https://example.com/v1'}));
});
