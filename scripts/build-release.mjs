import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {deflateRawSync} from 'node:zlib';
import {fileURLToPath} from 'node:url';
import {audit,readManifest,repoRoot} from './check-public.mjs';

const crcTable=Array.from({length:256},(_,n)=>{for(let k=0;k<8;k++)n=n&1?0xedb88320^(n>>>1):n>>>1;return n>>>0;});
function crc32(data){let crc=0xffffffff;for(const byte of data)crc=crcTable[(crc^byte)&255]^(crc>>>8);return (crc^0xffffffff)>>>0;}
export function zipEntries(entries){
  const local=[],central=[];let offset=0,centralSize=0;
  for(const {name,data} of entries){
    if(name.startsWith('/')||name.includes('\\')||name.split('/').some(s=>!s||s==='..'||s==='.'))throw new Error('Unsafe ZIP member name.');
    const filename=Buffer.from(name,'utf8'),body=deflateRawSync(data,{level:9}),crc=crc32(data);
    const head=Buffer.alloc(30);head.writeUInt32LE(0x04034b50,0);head.writeUInt16LE(20,4);head.writeUInt16LE(0x800,6);head.writeUInt16LE(8,8);head.writeUInt16LE(33,12);
    head.writeUInt32LE(crc,14);head.writeUInt32LE(body.length,18);head.writeUInt32LE(data.length,22);head.writeUInt16LE(filename.length,26);
    const cd=Buffer.alloc(46);cd.writeUInt32LE(0x02014b50,0);cd.writeUInt16LE(20,4);cd.writeUInt16LE(20,6);cd.writeUInt16LE(0x800,8);cd.writeUInt16LE(8,10);cd.writeUInt16LE(33,14);
    cd.writeUInt32LE(crc,16);cd.writeUInt32LE(body.length,20);cd.writeUInt32LE(data.length,24);cd.writeUInt16LE(filename.length,28);cd.writeUInt32LE(offset,42);
    local.push(head,filename,body);central.push(cd,filename);offset+=head.length+filename.length+body.length;centralSize+=cd.length+filename.length;
  }
  const end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50,0);end.writeUInt16LE(entries.length,8);end.writeUInt16LE(entries.length,10);end.writeUInt32LE(centralSize,12);end.writeUInt32LE(offset,16);
  return Buffer.concat([...local,...central,end]);
}
export function buildRelease(root=repoRoot){
  const check=audit(root);if(!check.ok)throw new Error('Public-content check failed. Run npm run check.');
  const files=readManifest(root).sort(),prefix=`opentypeless-azure-bridge-v${check.version}`;
  const entries=files.map(name=>{
    let text=fs.readFileSync(path.join(root,name),'utf8').replace(/\r\n/g,'\n');
    if(/\.(ps1|cmd)$/.test(name))text=text.replace(/\n/g,'\r\n');
    return {name:prefix+'/'+name,data:Buffer.from(text)};
  });
  const sha=data=>crypto.createHash('sha256').update(data).digest('hex');
  const sums=entries.map((entry,i)=>sha(entry.data)+'  '+files[i]).join('\n')+'\n';
  entries.push({name:prefix+'/SHA256SUMS.txt',data:Buffer.from(sums)});
  const directory=path.join(root,'dist');fs.mkdirSync(directory,{recursive:true});
  const archive=path.join(directory,prefix+'.zip'),bytes=zipEntries(entries);
  fs.writeFileSync(archive,bytes);fs.writeFileSync(archive+'.sha256',sha(bytes)+'  '+path.basename(archive)+'\n');
  return {archive,files:entries.length,sha256:sha(bytes)};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  try{console.log(JSON.stringify(buildRelease(),null,2));}catch(e){console.error(e.message);process.exitCode=1;}
}
