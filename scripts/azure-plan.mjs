import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {validateProfile} from '../runtime/foundry-bridge.mjs';

const guid=/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const name=/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/;
export function validateResources(c){
  if(c?.schemaVersion!==1||c.cloud!=='AzureCloud')throw new Error('schemaVersion 1 and AzureCloud are required.');
  for(const k of ['tenantId','subscriptionId'])if(!guid.test(c[k]||'')||/^0{8}-0{4}-0{4}-0{4}-0{12}$/.test(c[k]))throw new Error('Replace the '+k+' placeholder.');
  if(!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,89}$/.test(c.resourceGroup||''))throw new Error('Invalid resourceGroup.');
  if(!/^[a-z0-9][a-z0-9-]{1,62}$/.test(c.resourceName||''))throw new Error('Use a unique, lower-case resourceName/custom subdomain.');
  if(!/^[a-z][a-z0-9]{1,40}$/.test(c.location||''))throw new Error('Invalid Azure region ID.');
  if(!['AIServices','OpenAI'].includes(c.kind))throw new Error('kind must be AIServices or OpenAI.');
  if(c.principalObjectId!==null&&!guid.test(c.principalObjectId||''))throw new Error('Provide principalObjectId, or null to arrange RBAC manually.');
  if(!['User','Group','ServicePrincipal'].includes(c.principalType))throw new Error('Invalid principalType.');
  for(const m of [c.speech,c.polish]){
    if(!m||!name.test(m.deployment||'')||!name.test(m.model||'')||!name.test(m.version||''))throw new Error('Model, version and deployment ID are required.');
    if(!['GlobalStandard','Standard','DataZoneStandard'].includes(m.sku)||!Number.isInteger(m.capacity)||m.capacity<1||m.capacity>1000)throw new Error('Invalid model SKU/capacity.');
  }
  if(c.speech.deployment===c.polish.deployment)throw new Error('Speech and polish need different deployment IDs.');
  makeProfile(c);
  return c;
}
export function makeProfile(c){
  const rule={minimumOutputTokens:c.polish.minimumOutputTokens??32};
  if(c.polish.reasoningEffort!==undefined)rule.reasoningEffort=c.polish.reasoningEffort;
  return validateProfile({schemaVersion:1,cloud:c.cloud,tenantId:c.tenantId,
    azureEndpoint:`https://${c.resourceName}.cognitiveservices.azure.com`,polishEndpoint:`https://${c.resourceName}.openai.azure.com`,
    tokenResource:'https://cognitiveservices.azure.com/',audioApiVersion:'2025-03-01-preview',port:17863,
    defaultModel:c.speech.deployment,transcriptionDeployments:[c.speech.deployment],defaultLanguage:'zh',
    transcriptionPrompt:'中文口述，保留英文产品名称与技术术语。',polishModel:c.polish.deployment,
    polishDeployments:{[c.polish.deployment]:rule}});
}
export function describePlan(c){
  validateResources(c);
  const scope=`/subscriptions/${c.subscriptionId}/resourceGroups/${c.resourceGroup}/providers/Microsoft.CognitiveServices/accounts/${c.resourceName}`;
  const body={kind:c.kind,location:c.location,sku:{name:'S0'},properties:{customSubDomainName:c.resourceName,disableLocalAuth:true}};
  if(c.kind==='AIServices'){body.identity={type:'SystemAssigned'};body.properties.allowProjectManagement=true;}
  return {scope,accountApiVersion:'2025-06-01',accountBody:body,
    deployments:[c.speech,c.polish].map(m=>({id:m.deployment,args:['cognitiveservices','account','deployment','create','--subscription',c.subscriptionId,
      '--resource-group',c.resourceGroup,'--name',c.resourceName,'--deployment-name',m.deployment,'--model-format','OpenAI',
      '--model-name',m.model,'--model-version',m.version,'--sku-name',m.sku,'--sku-capacity',String(m.capacity)]})),
    roleArgs:c.principalObjectId?['role','assignment','create','--subscription',c.subscriptionId,'--assignee-object-id',c.principalObjectId,
      '--assignee-principal-type',c.principalType,'--role','Cognitive Services OpenAI User','--scope',scope]:null,
    profile:makeProfile(c)};
}
export function checkAzureState(c,s){
  validateResources(c);
  if(s.subscription?.tenantId?.toLowerCase()!==c.tenantId.toLowerCase()||s.subscription?.id?.toLowerCase()!==c.subscriptionId.toLowerCase())throw new Error('Signed-in subscription/tenant mismatch.');
  if(s.cloud!=='AzureCloud')throw new Error('This private CLI profile is not AzureCloud. Use the documented isolated sign-in.');
  if(s.providerState!=='Registered')throw new Error('Register Microsoft.CognitiveServices in the subscription first; see the Azure guide.');
  if(!Array.isArray(s.catalog)||!s.catalog.length||s.catalog.some(x=>!x||typeof x!=='object'))throw new Error('The model catalog is empty/unavailable or invalid; do not assume availability.');
  for(const m of [c.speech,c.polish]){
    const row=s.catalog.map(x=>x.model??x).find(x=>x.name===m.model&&x.version===m.version&&x.format==='OpenAI');
    const sku=row?.skus?.find(x=>x.name===m.sku);
    if(!sku)throw new Error(`Unavailable model/version/SKU: ${m.model} / ${m.version} / ${m.sku}. No automatic model substitution.`);
    const bounds=sku.capacity||{};
    if(bounds.minimum!=null&&m.capacity<bounds.minimum||bounds.maximum!=null&&m.capacity>bounds.maximum)throw new Error('Capacity outside model SKU bounds.');
    if(bounds.step&&((m.capacity-(bounds.minimum??0))%bounds.step!==0))throw new Error('Capacity does not match SKU step.');
    if(bounds.allowedValues?.length&&!bounds.allowedValues.includes(m.capacity))throw new Error('Capacity not in SKU allowedValues.');
  }
  if(s.account){
    if(s.account.kind!==c.kind||s.account.location?.toLowerCase()!==c.location||s.account.properties?.customSubDomainName!==c.resourceName)throw new Error('Existing account kind, region or subdomain differs; it will not be overwritten.');
    if(s.account.properties.provisioningState!=='Succeeded')throw new Error('Existing account is not Succeeded. Resolve it in Azure first.');
  }
  const missing=[];
  for(const m of [c.speech,c.polish]){
    const existing=(s.deployments||[]).find(d=>d.name===m.deployment);
    if(!existing){missing.push(m.deployment);continue;}
    const actual=existing.properties?.model;
    if(actual?.name!==m.model||actual?.version!==m.version||actual?.format!=='OpenAI'||existing.sku?.name!==m.sku)throw new Error('Existing deployment differs: '+m.deployment+'. Choose another deployment ID or review the change manually.');
    if(existing.properties.provisioningState!=='Succeeded')throw new Error('Existing deployment is not Succeeded: '+m.deployment);
  }
  return {valid:true,createResourceGroup:!s.groupExists,createAccount:!s.account,missingDeployments:missing,roleAlreadyAssigned:s.roleAlreadyAssigned===true,
    warnings:['Catalog availability does not guarantee remaining quota or live regional capacity.',
      ...(s.account&&s.account.properties.disableLocalAuth!==true?['Existing account permits local keys; this tool does not change shared account authentication.']:[]),
      ...(!c.principalObjectId?['RBAC must be granted separately before inference.']:[])]};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  try{
    const c=JSON.parse(fs.readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,''));
    const result=process.argv[3]?checkAzureState(c,JSON.parse(fs.readFileSync(process.argv[3],'utf8').replace(/^\uFEFF/,''))):describePlan(c);
    console.log(JSON.stringify(result,null,2));
  }catch(e){console.error(e.message);process.exitCode=1;}
}
