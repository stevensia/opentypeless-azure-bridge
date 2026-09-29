import test from 'node:test';
import assert from 'node:assert/strict';
import {describePlan,checkAzureState,validateResources} from '../scripts/azure-plan.mjs';
const config={schemaVersion:1,cloud:'AzureCloud',tenantId:'11111111-1111-1111-1111-111111111111',subscriptionId:'22222222-2222-2222-2222-222222222222',
  resourceGroup:'rg-example',resourceName:'example-resource',location:'eastus2',kind:'AIServices',principalObjectId:'33333333-3333-3333-3333-333333333333',principalType:'User',
  speech:{deployment:'speech-main',model:'gpt-transcribe',version:'2026-07-28',sku:'GlobalStandard',capacity:10},
  polish:{deployment:'polish-main',model:'gpt-6-sol',version:'2026-09-22',sku:'GlobalStandard',capacity:10,reasoningEffort:'none',minimumOutputTokens:32}};
const catalog=[config.speech,config.polish].map(m=>({model:{name:m.model,version:m.version,format:'OpenAI',skus:[{name:m.sku,capacity:{minimum:1,maximum:100,step:1}}]}}));
const state={cloud:'AzureCloud',providerState:'Registered',subscription:{id:config.subscriptionId,tenantId:config.tenantId},catalog,groupExists:false,account:null,deployments:[]};
test('Plan creates a key-disabled account and the requested models without mutating Azure',()=>{
  const p=describePlan(config);assert.equal(p.accountBody.properties.disableLocalAuth,true);assert.equal(p.accountBody.identity.type,'SystemAssigned');
  assert.equal(p.deployments.length,2);assert.ok(p.deployments[1].args.includes('gpt-6-sol'));assert.equal(p.profile.polishModel,'polish-main');
  assert.ok(p.roleArgs.includes('Cognitive Services OpenAI User'));assert.ok(!JSON.stringify(p).includes('Owner'));
});
test('Preflight identifies missing resources and keeps quota as unverified',()=>{
  const r=checkAzureState(config,state);assert.equal(r.createAccount,true);assert.equal(r.createResourceGroup,true);assert.equal(r.missingDeployments.length,2);assert.match(r.warnings[0],/quota/);
});
test('Preflight rejects wrong identity, unknown catalog, unavailable versions and invalid capacities',()=>{
  assert.throws(()=>checkAzureState(config,{...state,subscription:{...state.subscription,tenantId:'44444444-4444-4444-4444-444444444444'}}),/mismatch/);
  assert.throws(()=>checkAzureState(config,{...state,catalog:[]}),/empty/);
  assert.throws(()=>checkAzureState(config,{...state,catalog:[null]}),/invalid/);
  assert.throws(()=>checkAzureState({...config,polish:{...config.polish,version:'2099-01-01'}},state),/Unavailable/);
  assert.throws(()=>checkAzureState({...config,polish:{...config.polish,capacity:101}},state),/bounds/);
});
test('Matching resources are reused and conflicting deployments are never overwritten',()=>{
  const deployed=[config.speech,config.polish].map(m=>({name:m.deployment,sku:{name:m.sku},properties:{provisioningState:'Succeeded',model:{name:m.model,version:m.version,format:'OpenAI'}}}));
  const s={...state,groupExists:true,account:{kind:'AIServices',location:'eastus2',properties:{customSubDomainName:'example-resource',provisioningState:'Succeeded',disableLocalAuth:true}},deployments:deployed};
  assert.deepEqual(checkAzureState(config,s).missingDeployments,[]);
  const changed=structuredClone(s);changed.deployments[0].properties.model.name='another-model';assert.throws(()=>checkAzureState(config,changed),/differs/);
});
test('Resource placeholders and unknown presets fail before any execution',()=>{
  assert.throws(()=>validateResources({...config,tenantId:'<tenant-id>'}));
  assert.throws(()=>validateResources({...config,resourceName:'bad;command'}));
  assert.throws(()=>validateResources({...config,polish:{...config.polish,reasoningEffort:'unknown'}}));
  assert.equal(describePlan({...config,principalObjectId:null}).roleArgs,null);
});
