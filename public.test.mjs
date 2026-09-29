import test from 'node:test';
import assert from 'node:assert/strict';
import {scanText} from '../scripts/check-public.mjs';
import {zipEntries} from '../scripts/build-release.mjs';
import {inflateRawSync} from 'node:zlib';
test('Publication scan catches private identifiers without echoing their values',()=>{
  const id=['12345678','1234','4321','1234','123456789012'].join('-');
  const host='https://'+'private-customer'+'.openai.azure.com';
  const secret=['localApi','Key'].join('')+': "'+'a'.repeat(44)+'"';
  const result=scanText('config.json',id+'\n'+host+'\n'+secret);
  assert.deepEqual(result.map(x=>x.rule),['non-example-guid','non-example-azure-host','literal-credential']);
  assert.equal(JSON.stringify(result).includes(id),false);assert.equal(JSON.stringify(result).includes('a'.repeat(44)),false);
});
test('Examples and clearly synthetic test credentials are allowed',()=>{
  assert.deepEqual(scanText('tests/fixture.mjs','tenant="11111111-1111-1111-1111-111111111111"; localApiKey: "unit-test-secret"; https://example-resource.openai.azure.com'),[]);
});
test('Runtime and private files cannot become release members',()=>{
  for(const file of ['.local/profile.json','runtime/bridge-config.json','x/client.pem','backups/old.json','runtime/guardian-state.json','artifact.exe'])
    assert.ok(scanText(file,'{}').some(x=>x.rule==='runtime-or-secret-file'));
});
test('ZIP builder is deterministic and preserves Unicode source bytes',()=>{
  const entries=[{name:'demo/说明.md',data:Buffer.from('中文\n')}];
  const first=zipEntries(entries),second=zipEntries(entries);assert.deepEqual(first,second);
  assert.equal(first.readUInt32LE(0),0x04034b50);
  const filenameLength=first.readUInt16LE(26),bodyLength=first.readUInt32LE(18),begin=30+filenameLength;
  assert.equal(inflateRawSync(first.subarray(begin,begin+bodyLength)).toString(),'中文\n');
  assert.throws(()=>zipEntries([{name:'../escape',data:Buffer.alloc(0)}]),/Unsafe/);
});
