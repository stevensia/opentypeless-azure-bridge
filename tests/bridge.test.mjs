import fs from 'node:fs';
const profile=JSON.parse(fs.readFileSync(new URL('./fixtures/profile.json', import.meta.url),'utf8'));
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createBridge, isDigitalSilenceWav } from '../runtime/foundry-bridge.mjs';

async function fixture(t, overrides = {}) {
  const calls = [];
  const config = { ...profile, defaultModel: 'gpt-4o-transcribe', localApiKey: 'unit-test-secret', ...overrides };
  const server = createBridge({ config, getToken: async () => 'cloud-token',
    fetchImpl: async (url, options) => { calls.push({ url, options }); return Response.json({ text: '连接测试成功。' }); } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  return { calls, base: 'http://127.0.0.1:' + server.address().port };
}
function upload(model = 'gpt-4o-transcribe') {
  const form = new FormData(); form.set('model', model); form.set('file', new Blob(['test audio']), 'test.wav'); return form;
}
test('Reject unauthorized calls without contacting Azure', async t => {
  const { base, calls } = await fixture(t);
  assert.equal((await fetch(base + '/v1/audio/transcriptions', { method: 'POST', body: upload() })).status, 401);
  assert.equal(calls.length, 0);
});
test('Reject web origins and foreign host headers', async t => {
  const { base, calls } = await fixture(t);
  assert.equal((await fetch(base + '/health', { headers: { Origin: 'https://example.com' } })).status, 403);
  const status = await new Promise((resolve, reject) => {
    http.get(base + '/health', { headers: { Host: 'attacker.example' } }, response => {
      response.resume(); resolve(response.statusCode);
    }).on('error', reject);
  });
  assert.equal(status, 403);
  assert.equal(calls.length, 0);
});
test('Forward transcription only with Azure identity, preserving result', async t => {
  const { base, calls } = await fixture(t);
  const response = await fetch(base + '/v1/audio/transcriptions', { method: 'POST',
    headers: { Authorization: 'Bearer unit-test-secret' }, body: upload() });
  assert.equal(response.status, 200); assert.equal((await response.json()).text, '连接测试成功。');
  assert.equal(calls.length, 1); assert.equal(calls[0].options.headers.Authorization, 'Bearer cloud-token');
  assert.match(calls[0].url, /^https:\/\/example-resource\.cognitiveservices\.azure\.com\/openai\/deployments\/gpt-4o-transcribe\/audio\/transcriptions\?/);
  assert.equal(calls[0].options.body.get('model'), 'gpt-4o-transcribe');
});
test('Reject other models and routes without contacting Azure', async t => {
  const { base, calls } = await fixture(t);
  const headers = { Authorization: 'Bearer unit-test-secret' };
  assert.equal((await fetch(base + '/v1/audio/transcriptions', { method: 'POST', headers, body: upload('other') })).status, 400);
  assert.equal((await fetch(base + '/v1/chat/completions', { method: 'POST', headers })).status, 404);
  assert.equal(calls.length, 0);
});
test('New Azure deployment receives documented language and terminology fields', async t => {
  const { base, calls } = await fixture(t, { defaultModel: 'speech-main',
    defaultLanguage: 'zh', transcriptionPrompt: '产品名称：OpenTypeless、Azure CLI。' });
  const response = await fetch(base + '/v1/audio/transcriptions', { method: 'POST',
    headers: { Authorization: 'Bearer unit-test-secret' }, body: upload('speech-main') });
  assert.equal(response.status, 200);
  assert.match(calls[0].url, /\/deployments\/speech-main\/audio\/transcriptions\?/);
  assert.equal(calls[0].options.body.get('model'), 'speech-main');
  assert.equal(calls[0].options.body.get('language'), 'zh');
  assert.equal(calls[0].options.body.get('prompt'), '产品名称：OpenTypeless、Azure CLI。');
  assert.equal(calls[0].options.body.has('languages[]'), false);
  assert.equal(calls[0].options.body.has('keywords[]'), false);
  const health = await (await fetch(base + '/health')).json();
  assert.equal(health.model, 'speech-main');
  assert.equal(health.lastDeployment, 'speech-main');
});
test('Explicit client context takes precedence and mini uses its own deployment', async t => {
  const { base, calls } = await fixture(t, { defaultLanguage: 'zh', transcriptionPrompt: 'Default' });
  const form = upload('speech-mini');
  form.set('language', 'en'); form.set('prompt', 'Client context');
  const response = await fetch(base + '/v1/audio/transcriptions', { method: 'POST',
    headers: { Authorization: 'Bearer unit-test-secret' }, body: form });
  assert.equal(response.status, 200);
  assert.match(calls[0].url, /\/deployments\/speech-mini\//);
  assert.equal(calls[0].options.body.get('language'), 'en');
  assert.equal(calls[0].options.body.get('prompt'), 'Client context');
});
function silentWav() {
  const b = Buffer.alloc(3244);
  b.write('RIFF'); b.writeUInt32LE(3236, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28);
  b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(3200, 40);
  return b;
}
test('Digital silence detection does not discard quiet speech or unknown audio formats', () => {
  assert.equal(isDigitalSilenceWav(silentWav()), true);
  const quiet = silentWav(); quiet.writeInt16LE(1, 100);
  assert.equal(isDigitalSilenceWav(quiet), false);
  assert.equal(isDigitalSilenceWav(Buffer.alloc(3200)), false);
  const malformed = silentWav(); malformed.writeUInt32LE(999999, 40);
  assert.equal(isDigitalSilenceWav(malformed), false);
});
test('Silent app connection test still calls Azure but does not invent a transcript', async t => {
  const { base, calls } = await fixture(t, { defaultLanguage: 'zh', transcriptionPrompt: 'Azure OpenTypeless' });
  const form = upload('speech-main');
  form.set('file', new Blob([silentWav()], { type: 'audio/wav' }), 'test.wav');
  const response = await fetch(base + '/v1/audio/transcriptions', { method: 'POST',
    headers: { Authorization: 'Bearer unit-test-secret' }, body: form });
  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.body.has('prompt'), false);
  assert.equal((await response.json()).text, '');
});

async function polishFixture(t, responder) {
  const calls = [];
  const server = createBridge({ config: {...profile, localApiKey: 'polish-unit-test-key'}, getToken: async () => 'azure-token',
    fetchImpl: async (url, options) => { calls.push({url, options}); return responder(); } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  return {calls, base:'http://127.0.0.1:'+server.address().port};
}
async function polishCall(base, body, key='polish-unit-test-key') {
  return fetch(base+'/polish/v1/chat/completions', {method:'POST',
    headers:{'Content-Type':'application/json',Authorization:'Bearer '+key},body:JSON.stringify(body)});
}
test('Polish adapts GPT-5.2 limits and preserves application instructions', async t => {
  const {base,calls}=await polishFixture(t,()=>Response.json({choices:[{message:{content:'润色成功'}}]}));
  const messages=[{role:'system',content:'Keep exact instructions'},{role:'user',content:'嗯你好'}];
  const response=await polishCall(base,{model:'gpt-5.2',messages,max_tokens:4096,temperature:0.3});
  assert.equal(response.status,200);assert.equal((await response.json()).choices[0].message.content,'润色成功');
  const sent=JSON.parse(calls[0].options.body);
  assert.deepEqual(sent.messages,messages);assert.equal(sent.max_completion_tokens,4096);
  assert.equal(sent.reasoning_effort,'none');assert.equal(sent.max_tokens,undefined);assert.equal(sent.temperature,undefined);
  assert.equal(calls[0].options.headers.Authorization,'Bearer azure-token');
  assert.match(calls[0].url,/^https:\/\/example-resource\.openai\.azure\.com\/openai\/v1\/chat\/completions$/);
});
test('Polish forwards UTF-8 SSE bytes and DONE without breaking streaming',async t=>{
  const content='data: {"choices":[{"delta":{"content":"中文润色"}}]}\n\ndata: [DONE]\n\n';
  const {base}=await polishFixture(t,()=>new Response(content,{headers:{'Content-Type':'text/event-stream'}}));
  const response=await polishCall(base,{model:'gpt-4o',messages:[{role:'user',content:'你好'}],stream:true});
  assert.equal(response.status,200);assert.equal(await response.text(),content);
});
test('Polish blocks wrong keys and models before contacting Azure',async t=>{
  const {base,calls}=await polishFixture(t,()=>{throw new Error('Must not call Azure')});
  assert.equal((await polishCall(base,{model:'gpt-5.2',messages:[{}]},'wrong')).status,401);
  assert.equal((await polishCall(base,{model:'unapproved',messages:[{}]})).status,400);
  assert.equal(calls.length,0);
  const models=await (await fetch(base+'/polish/v1/models',{headers:{Authorization:'Bearer polish-unit-test-key'}})).json();
  assert.deepEqual(models.data.map(x=>x.id),['polish-main','polish-alternative','gpt-5.2','gpt-4o']);
});
test('Polish reports Azure auth failures without returning a fake success',async t=>{
  const {base}=await polishFixture(t,()=>Response.json({error:{code:'PermissionDenied',message:'Access denied'}},{status:403}));
  const response=await polishCall(base,{model:'gpt-5.2',messages:[{role:'user',content:'Hi'}]});
  assert.equal(response.status,403);assert.equal((await response.json()).error.code,'PermissionDenied');
});
test('App one-token connection probe gets a small GPT-5.2 compatible budget',async t=>{
  const {base,calls}=await polishFixture(t,()=>Response.json({choices:[{message:{content:'Hi'}}]}));
  const response=await polishCall(base,{model:'gpt-5.2',messages:[{role:'user',content:'hi'}],max_tokens:1});
  assert.equal(response.status,200);assert.equal(JSON.parse(calls[0].options.body).max_completion_tokens,32);
});
test('Advanced deployments use Azure deployment IDs and compatible low-latency parameters',async t=>{
  const {base,calls}=await polishFixture(t,()=>Response.json({choices:[{message:{content:'Ready'}}]}));
  for(const model of ['polish-alternative','polish-main']){
    const response=await polishCall(base,{model,messages:[{role:'user',content:'hi'}],max_tokens:1,temperature:0.3});
    assert.equal(response.status,200);
    const sent=JSON.parse(calls.at(-1).options.body);
    assert.equal(sent.model,model);assert.equal(sent.reasoning_effort,'none');
    assert.equal(sent.max_completion_tokens,32);assert.equal(sent.temperature,undefined);
  }
});
