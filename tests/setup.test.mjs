import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {applySettings,checkSettings,restoreSettings,readSettings} from '../runtime/app-settings.mjs';
import {validateProfile,createBridge,azureTokenProvider} from '../runtime/foundry-bridge.mjs';

const profile=JSON.parse(fs.readFileSync(new URL('./fixtures/profile.json',import.meta.url),'utf8'));
const config={...profile,localApiKey:'random-key-created-only-for-unit-test'};
const original={onboarding_completed:true,rootExtra:{keep:'yes'},app_config:{
  stt_provider:'custom-whisper',stt_api_key:'',stt_custom_api_key:'',stt_custom_base_url:'http://127.0.0.1:9000/v1',stt_custom_model:'old-speech',
  llm_provider:'openai',llm_model:'old-model',llm_base_url:'https://example.com/v1',llm_api_key:'',polish_enabled:false,
  hotkey:'Alt+X',hotkeys:{dictation:['Ctrl+/','Alt+X']},theme:'dark',polish_custom_prompt:'保留我设置的提示词',future_field:{nested:42}}};
function fixture(t){
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'ot-setup-test-'));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const file=path.join(dir,'settings.json');
  fs.writeFileSync(file,JSON.stringify(original));
  return {file,dir};
}
test('Merge preserves shortcuts, custom prompts, root values, and future settings',t=>{
  const {file,dir}=fixture(t);const r=applySettings(file,config,path.join(dir,'backups'));
  const changed=readSettings(file);
  assert.equal(r.changed,true);assert.deepEqual(changed.rootExtra,original.rootExtra);
  for(const k of ['hotkey','hotkeys','theme','polish_custom_prompt','future_field'])assert.deepEqual(changed.app_config[k],original.app_config[k]);
  assert.equal(changed.app_config.llm_model,profile.polishModel);assert.equal(changed.app_config.stt_custom_api_key,config.localApiKey);
  assert.equal(changed.app_config.stt_api_key,'');assert.equal(checkSettings(file,config).matches,true);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(r.backup,'settings.before.json'))),original);
});
test('Repeated apply does not rotate a key or create another backup before app migration',t=>{
  const {file,dir}=fixture(t);applySettings(file,config,path.join(dir,'backups'));
  const bytes=fs.readFileSync(file);const r=applySettings(file,config,path.join(dir,'backups'));
  assert.equal(r.changed,false);assert.deepEqual(fs.readFileSync(file),bytes);assert.equal(fs.readdirSync(path.join(dir,'backups')).length,1);
});
test('Unsupported schema leaves settings intact and creates no backup',t=>{
  const {file,dir}=fixture(t);fs.writeFileSync(file,'{"other":"schema"}');
  assert.throws(()=>applySettings(file,config,path.join(dir,'backups')),/schema/);
  assert.equal(fs.readFileSync(file,'utf8'),'{"other":"schema"}');assert.equal(fs.existsSync(path.join(dir,'backups')),false);
});
test('Rollback restores managed fields and preserves subsequent unrelated user edits',t=>{
  const {file,dir}=fixture(t);const r=applySettings(file,config,path.join(dir,'backups'));
  const data=readSettings(file);data.app_config.hotkey='Alt+N';data.app_config.llm_api_key='';data.app_config.stt_custom_api_key='';
  fs.writeFileSync(file,JSON.stringify(data));restoreSettings(file,r.backup);
  assert.equal(readSettings(file).app_config.hotkey,'Alt+N');assert.equal(readSettings(file).app_config.llm_model,'old-model');
});
test('Rollback refuses to overwrite a model subsequently chosen by the user',t=>{
  const {file,dir}=fixture(t);const r=applySettings(file,config,path.join(dir,'backups'));
  const data=readSettings(file);data.app_config.llm_model='user-picked';fs.writeFileSync(file,JSON.stringify(data));
  assert.throws(()=>restoreSettings(file,r.backup),/changed since setup/);assert.equal(readSettings(file).app_config.llm_model,'user-picked');
});
test('Config check never reports vault authentication as tested',t=>{
  const {file,dir}=fixture(t);applySettings(file,config,path.join(dir,'backups'));
  const data=readSettings(file);data.app_config.llm_api_key='';data.app_config.stt_custom_api_key='';fs.writeFileSync(file,JSON.stringify(data));
  const status=checkSettings(file,config);assert.equal(status.matches,true);assert.equal(status.secretsStaged,false);assert.match(status.vaultVerification,/Not inspected/);
});
test('Reject non-Azure endpoints, embedded credentials, paths, and unknown default deployments',()=>{
  for(const endpoint of ['http://example.com','https://evil.example','https://user@foo.openai.azure.com','https://foo.openai.azure.com/path','https://foo.openai.azure.com?x=1'])
    assert.throws(()=>validateProfile({...profile,polishEndpoint:endpoint}));
  assert.throws(()=>validateProfile({...profile,polishModel:'missing'}));
  assert.throws(()=>validateProfile({...profile,cloud:'AzureChinaCloud'}));
  assert.throws(()=>createBridge({config:{...profile,localApiKey:''}}));
});
test('New Azure resource and deployment IDs require only profile changes',async t=>{
  const c={...config,azureEndpoint:'https://another-resource.cognitiveservices.azure.com',polishEndpoint:'https://another-resource.openai.azure.com',
    defaultModel:'new-stt',transcriptionDeployments:['new-stt'],polishModel:'new-polish',polishDeployments:{'new-polish':{reasoningEffort:'none',minimumOutputTokens:32}}};
  let called;
  const s=createBridge({config:c,getToken:async()=>'unit-token',fetchImpl:async(url,options)=>{called={url,body:JSON.parse(options.body)};return Response.json({choices:[]});}});
  await new Promise(r=>s.listen(0,'127.0.0.1',r));t.after(()=>{s.closeAllConnections();s.close()});
  const r=await fetch(`http://127.0.0.1:${s.address().port}/polish/v1/chat/completions`,{method:'POST',headers:{Authorization:'Bearer '+c.localApiKey,'Content-Type':'application/json'},body:JSON.stringify({model:'new-polish',messages:[{role:'user',content:'hi'}],max_tokens:1})});
  assert.equal(r.status,200);assert.match(called.url,/another-resource.openai.azure.com/);assert.equal(called.body.model,'new-polish');assert.equal(called.body.max_completion_tokens,32);
});
test('Token provider deduplicates concurrent refresh and uses isolated CLI config',async()=>{
  let calls=0;
  const c={powershellPath:'powershell.exe',installDir:'C:\\Test Bridge',azureConfigDir:'C:\\Test Auth'};
  const get=azureTokenProvider(c,async(file,args,options)=>{
    calls++;assert.equal(file,'powershell.exe');assert.equal(options.env.AZURE_CONFIG_DIR,c.azureConfigDir);assert.equal(options.windowsHide,true);
    assert.ok(args.includes('-NonInteractive'));assert.equal(options.shell,undefined);
    return {stdout:JSON.stringify({accessToken:'fake-token',expires_on:Math.floor(Date.now()/1000)+3600})};
  });
  assert.deepEqual(await Promise.all([get(),get(),get()]),['fake-token','fake-token','fake-token']);await get();assert.equal(calls,1);
});
test('Token errors are sanitized and retry on the next call',async()=>{
  let calls=0;const get=azureTokenProvider({installDir:'.'},async()=>{calls++;throw new Error('do-not-display-sensitive-stderr');});
  for(let i=0;i<2;i++)await assert.rejects(get(),e=>e.status===503&&!e.message.includes('sensitive-stderr'));
  assert.equal(calls,2);
});
