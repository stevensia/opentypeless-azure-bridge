import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const directory=fileURLToPath(new URL('../tests/',import.meta.url));
const files=fs.readdirSync(directory).filter(x=>x.endsWith('.test.mjs')).sort().map(x=>directory+'/'+x);
try{execFileSync(process.execPath,['--test',...files],{stdio:'inherit'});}catch(e){process.exitCode=e.status||1;}
