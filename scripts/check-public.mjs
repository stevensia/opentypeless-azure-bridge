import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';

export const repoRoot=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const forbiddenPath=/(^|\/)(?:\.local|azure-auth|provisioning-auth|backups|node_modules|dist|artifacts)(?:\/|$)|(?:^|\/)(?:bridge-config|guardian-config|guardian-state|guardian-live-validation|process|settings[^/]*|msal_[^/]*|service_principal_entries[^/]*)\.json$|\.local\.json$|\.(?:pem|pfx|p12|key|log|exe|dll|zip)$/i;
const sampleHost=/^(?:example(?:-[a-z0-9]+)*|demo(?:-[a-z0-9]+)*|your(?:-[a-z0-9]+)*|test(?:-[a-z0-9]+)*|another-resource|foo)$/;
const sampleGuid=/^([0-9a-f])\1{7}-\1{4}-\1{4}-\1{4}-\1{12}$/i;
const dummySecret=/^(?:unit-test|polish-unit-test-|test-|fake-|dummy-|cloud-token$|azure-token$|random-key-created-only-for-unit-test$)/i;

export function scanText(file,text){
  const found=[];
  const add=(rule,index=0)=>found.push({file,line:1+text.slice(0,index).split('\n').length-1,rule});
  if(forbiddenPath.test(file))add('runtime-or-secret-file');
  if(text.includes('\0'))add('unexpected-binary-file');
  for(const m of text.matchAll(/[a-zA-Z]:[\\/]+Users[\\/]+[^\s"'<>\\/]+/g))add('personal-absolute-path',m.index);
  for(const m of text.matchAll(/\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b/gi))if(!sampleGuid.test(m[0]))add('non-example-guid',m.index);
  for(const m of text.matchAll(/https:\/\/([a-z0-9-]+)\.(?:cognitiveservices|openai)\.azure\.com/gi))if(!sampleHost.test(m[1]))add('non-example-azure-host',m.index);
  for(const m of text.matchAll(/(?:localApiKey|accessToken|clientSecret|password)["']?\s*[:=]\s*["']([^"'\r\n]+)["']/gi)){
    if(!dummySecret.test(m[1])&&!['.','apiKey'].includes(m[1]))add('literal-credential',m.index);
  }
  const privateHeader=['-----BEGIN ', '(?:RSA |EC |OPENSSH )?', 'PRIVATE KEY-----'].join('');
  for(const m of text.matchAll(new RegExp(privateHeader,'g')))add('private-key',m.index);
  for(const m of text.matchAll(/\beyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b/g))add('jwt',m.index);
  for(const m of text.matchAll(/\b(?:ghp_|github_pat_|sk-proj-)[A-Za-z0-9_-]{24,}\b/g))add('provider-secret',m.index);
  return found;
}

export function readManifest(root=repoRoot){
  const files=JSON.parse(fs.readFileSync(path.join(root,'release-files.json'),'utf8'));
  if(!Array.isArray(files)||!files.length||new Set(files).size!==files.length)throw new Error('Invalid release file list.');
  for(const file of files){
    if(typeof file!=='string'||file.includes('\\')||file.startsWith('/')||file.split('/').some(s=>!s||s==='.'||s==='..')||forbiddenPath.test(file))throw new Error('Unsafe release path.');
    const absolute=path.resolve(root,file);
    if(!fs.lstatSync(absolute).isFile()||fs.lstatSync(absolute).isSymbolicLink())throw new Error('Only ordinary source files are publishable: '+file);
    const relative=path.relative(fs.realpathSync(root),fs.realpathSync(absolute));
    if(relative.startsWith('..'+path.sep)||path.isAbsolute(relative))throw new Error('Release path escapes source root.');
  }
  return files;
}

export function audit(root=repoRoot,{history=false}={}){
  const files=readManifest(root);let findings=[];
  for(const file of files)findings.push(...scanText(file,fs.readFileSync(path.join(root,file),'utf8')));
  const version=fs.readFileSync(path.join(root,'VERSION'),'utf8').trim();
  if(!/^\d+\.\d+\.\d+(?:-[a-z0-9.]+)?$/.test(version))throw new Error('Invalid project version.');
  if(JSON.parse(fs.readFileSync(path.join(root,'package.json'),'utf8')).version!==version)throw new Error('package.json version differs.');
  for(const file of ['runtime/foundry-bridge.mjs','runtime/BridgeGuardian.cs'])if(!fs.readFileSync(path.join(root,file),'utf8').includes('"'+version+'"')&&!fs.readFileSync(path.join(root,file),'utf8').includes("'"+version+"'"))throw new Error('Runtime version differs: '+file);
  let tracked=[];
  try{tracked=execFileSync('git',['ls-files','-z'],{cwd:root,encoding:'utf8',stdio:['ignore','pipe','pipe']}).split('\0').filter(Boolean);}catch{}
  for(const file of tracked)if(!files.includes(file))findings.push({file,line:0,rule:'tracked-but-not-in-release-list'});
  if(history){
    const revisions=execFileSync('git',['rev-list','--all'],{cwd:root,encoding:'utf8'}).trim().split('\n').filter(Boolean);
    for(const revision of revisions){
      const names=execFileSync('git',['ls-tree','-r','--name-only','-z',revision],{cwd:root,encoding:'utf8'}).split('\0').filter(Boolean);
      for(const file of names){
        const text=execFileSync('git',['show',revision+':'+file],{cwd:root,encoding:'utf8',maxBuffer:4*1024*1024});
        findings.push(...scanText(file,text).map(x=>({...x,revision:revision.slice(0,12)})));
      }
    }
  }
  return {ok:findings.length===0,files:files.length,version,findings};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  try{const result=audit(repoRoot,{history:process.argv.includes('--history')});console.log(JSON.stringify(result,null,2));if(!result.ok)process.exitCode=1;}
  catch(e){console.error(e.message);process.exitCode=1;}
}
