// Offline CLI double for the provisioning wrapper; never calls Azure.
import fs from 'node:fs';
import path from 'node:path';
const dir=process.env.OT_AZ_TEST_ROOT;if(!dir)throw new Error('Test root required.');
const config=JSON.parse(fs.readFileSync(path.join(dir,'resources.json'),'utf8'));
const file=path.join(dir,'fake-state.json');
const state=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{group:false,account:null,deployments:[],role:false,mutations:0,calls:[]};
const args=process.argv.slice(2),starts=(...prefix)=>prefix.every((x,i)=>args[i]===x),value=k=>args[args.indexOf(k)+1];
state.calls.push(args.slice(0,4));let result;
if(starts('account','show'))result={id:config.subscriptionId,tenantId:config.tenantId};
else if(starts('cloud','show'))result={name:'AzureCloud'};
else if(starts('provider','show'))result={registrationState:'Registered'};
else if(starts('cognitiveservices','model','list'))result=[config.speech,config.polish].map(m=>({model:{name:m.model,version:m.version,format:'OpenAI',skus:[{name:m.sku,capacity:{minimum:1,maximum:100}}]}}));
else if(starts('group','exists'))result=state.group;
else if(starts('group','create')){state.group=true;state.mutations++;result={};}
else if(starts('resource','create')){
  const body=JSON.parse(fs.readFileSync(value('--properties').slice(1),'utf8'));
  if(body.properties.disableLocalAuth!==true||body.kind!=='AIServices')throw new Error('Unexpected resource body.');
  state.account={...body,name:config.resourceName,properties:{...body.properties,provisioningState:'Succeeded'}};state.mutations++;result={};
}
else if(starts('cognitiveservices','account','list'))result=state.account?[state.account]:[];
else if(starts('cognitiveservices','account','deployment','list'))result=state.deployments;
else if(starts('cognitiveservices','account','deployment','create')){
  const item={name:value('--deployment-name'),sku:{name:value('--sku-name')},properties:{provisioningState:'Succeeded',model:{name:value('--model-name'),version:value('--model-version'),format:value('--model-format')}}};
  state.deployments.push(item);state.mutations++;result=item;
}
else if(starts('cognitiveservices','account','deployment','show'))result=state.deployments.find(x=>x.name===value('--deployment-name'));
else if(starts('role','assignment','list'))result=state.role?[{principalId:config.principalObjectId,roleDefinitionName:'Cognitive Services OpenAI User'}]:[];
else if(starts('role','assignment','create')){state.role=true;state.mutations++;result={};}
else throw new Error('Unexpected CLI command: '+args.slice(0,4).join(' '));
if(!args.includes('--subscription')&&!starts('cloud','show'))throw new Error('Subscription must be explicit.');
fs.writeFileSync(file,JSON.stringify(state));
if(value('--output')!=='none')process.stdout.write(JSON.stringify(result)+'\n');
