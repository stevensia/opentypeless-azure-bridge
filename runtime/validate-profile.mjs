import fs from 'node:fs';
import {validateProfile} from './foundry-bridge.mjs';
try {
  validateProfile(JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/,'')));
  console.log('Azure profile valid.');
} catch (e) { console.error(e.message); process.exitCode=1; }
