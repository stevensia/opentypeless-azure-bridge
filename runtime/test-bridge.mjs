import fs from 'node:fs';
import crypto from 'node:crypto';
const raw=fs.readFileSync(process.argv[2]);
const config=JSON.parse(raw.toString('utf8').replace(/^\uFEFF/,''));
const base=`http://127.0.0.1:${config.port}`;
const headers={Authorization:'Bearer '+config.localApiKey};
const result={checkedAt:new Date().toISOString(),live:process.argv.includes('--live'),checks:[]};
async function check(name,action){
  const start=Date.now();
  try {const detail=await action();result.checks.push({name,ok:true,elapsedMs:Date.now()-start,...detail});}
  catch(e){result.checks.push({name,ok:false,elapsedMs:Date.now()-start,error:e.message});process.exitCode=1;}
}
async function request(route,options={}) {
  const r=await fetch(base+route,{...options,signal:AbortSignal.timeout(70000)});
  if(!r.ok) {
    let code='';try{code=(await r.json()).error?.code||'';}catch{}
    throw new Error(`HTTP ${r.status}${code ? ' / '+code : ''}`);
  }
  return r;
}
await check('health',async()=>{
  const h=await (await request('/health')).json();
  if(h.service!=='OpenTypeless Foundry Bridge'||h.configHash!==crypto.createHash('sha256').update(raw).digest('hex'))throw new Error('Different bridge/config is listening on this port.');
  return {version:h.version};
});
await check('unauthorized-rejected',async()=>{
  const r=await fetch(base+'/v1/models',{signal:AbortSignal.timeout(5000)});
  if(r.status!==401)throw new Error('Expected HTTP 401.');
  return {status:r.status};
});
for(const [route,model] of [['/v1/models',config.defaultModel],['/polish/v1/models',config.polishModel]]){
  await check(route,async()=>{
    const r=await (await request(route,{headers})).json();
    if(!r.data?.some(x=>x.id===model))throw new Error('Default deployment missing from allowlist.');
    return {deployment:model};
  });
}
if(result.live && !process.exitCode){
  await check('azure-polish-stream',async()=>{
    const r=await request('/polish/v1/chat/completions',{method:'POST',headers:{...headers,'Content-Type':'application/json'},
      body:JSON.stringify({model:config.polishModel,stream:true,max_tokens:128,temperature:0.3,
        messages:[{role:'system',content:'整理口述内容，删除语气词和重复，保留原意、时间和技术名词。只输出整理后的正文。'},
          {role:'user',content:'嗯我们星期四，不对，星期五检查 Azure CLI 的权限，不要删除原来的配置。'}]})});
    const body=await r.text();
    let output='',model=null;
    for(const line of body.split(/\r?\n/))if(line.startsWith('data: ')&&line!=='data: [DONE]'){
      const item=JSON.parse(line.slice(6));if(item.error)throw new Error('Azure stream error.');
      model=item.model||model;output+=item.choices?.[0]?.delta?.content||'';
    }
    if(!body.includes('data: [DONE]')||!output.trim())throw new Error('Incomplete or empty SSE stream.');
    return {deployment:config.polishModel,returnedModel:model,outputCharacters:output.length};
  });
  await check('azure-audio-connection',async()=>{
    const wav=Buffer.alloc(3244);wav.write('RIFF');wav.writeUInt32LE(3236,4);wav.write('WAVEfmt ',8);wav.writeUInt32LE(16,16);
    wav.writeUInt16LE(1,20);wav.writeUInt16LE(1,22);wav.writeUInt32LE(16000,24);wav.writeUInt32LE(32000,28);
    wav.writeUInt16LE(2,32);wav.writeUInt16LE(16,34);wav.write('data',36);wav.writeUInt32LE(3200,40);
    const form=new FormData();form.set('model',config.defaultModel);form.set('file',new Blob([wav],{type:'audio/wav'}),'test.wav');
    const r=await (await request('/v1/audio/transcriptions',{method:'POST',headers,body:form})).json();
    if(typeof r.text!=='string')throw new Error('No transcript field.');
    return {deployment:config.defaultModel,note:'Synthetic silence verifies authentication and endpoint, not recognition accuracy.'};
  });
}
console.log(JSON.stringify(result,null,2));
