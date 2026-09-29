import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const keys = ['stt_provider','stt_api_key','stt_custom_api_key','stt_custom_preset','stt_custom_base_url',
  'stt_custom_model','stt_language','llm_provider','llm_api_key','llm_base_url','llm_model','polish_enabled'];
const secretKeys = ['stt_api_key', 'stt_custom_api_key', 'llm_api_key'];

export function readSettings(settingsPath) {
  const data = readJson(settingsPath);
  if (!data.app_config || typeof data.app_config !== 'object' || Array.isArray(data.app_config))
    throw new Error('Unsupported settings schema. Run OpenTypeless once and finish onboarding, then exit it.');
  for (const key of ['stt_provider','stt_custom_base_url','stt_custom_model','llm_provider','llm_model','llm_base_url']) {
    if (typeof data.app_config[key] !== 'string') throw new Error('Missing app_config field: ' + key);
  }
  return data;
}

export function targetSettings(config) {
  return {
    stt_provider: 'custom-whisper', stt_api_key: '', stt_custom_api_key: config.localApiKey,
    stt_custom_preset: 'custom', stt_custom_base_url: `http://127.0.0.1:${config.port}/v1`,
    stt_custom_model: config.defaultModel, stt_language: config.defaultLanguage,
    llm_provider: 'openai', llm_api_key: config.localApiKey,
    llm_base_url: `http://127.0.0.1:${config.port}/polish/v1`, llm_model: config.polishModel, polish_enabled: true
  };
}

function atomicWrite(file, value, previousHash) {
  if (digest(fs.readFileSync(file)) !== previousHash) throw new Error('Settings changed concurrently. Exit the app and retry.');
  const tmp = file + '.' + crypto.randomUUID() + '.tmp';
  try {
    fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n', {flag:'wx', mode:0o600});
    if (digest(fs.readFileSync(file)) !== previousHash) throw new Error('Settings changed concurrently; no replacement performed.');
    fs.renameSync(tmp, file);
  } finally { if (fs.existsSync(tmp)) fs.unlinkSync(tmp); }
}

export function applySettings(settingsPath, config, backupRoot) {
  const raw = fs.readFileSync(settingsPath);
  const data = readSettings(settingsPath);
  const values = targetSettings(config);
  const nonSecretMatches = keys.filter(k => !secretKeys.includes(k)).every(k => data.app_config[k] === values[k]);
  const explicitSecretsMatch = ['llm_api_key','stt_custom_api_key'].every(k => data.app_config[k] === config.localApiKey);
  if (nonSecretMatches && explicitSecretsMatch) return {changed:false, credentialState:'pending-app-migration'};
  const id = new Date().toISOString().replace(/[:.]/g,'-') + '-' + crypto.randomBytes(3).toString('hex');
  const directory = path.join(backupRoot, id);
  fs.mkdirSync(directory, {recursive:true});
  fs.writeFileSync(path.join(directory, 'settings.before.json'), raw, {flag:'wx', mode:0o600});
  const before = Object.fromEntries(keys.map(k => [k, {exists:Object.hasOwn(data.app_config,k), value:data.app_config[k]}]));
  fs.writeFileSync(path.join(directory, 'changes.json'), JSON.stringify({settingsPath,before,after:values},null,2), {flag:'wx',mode:0o600});
  Object.assign(data.app_config, values);
  atomicWrite(settingsPath, data, digest(raw));
  return {changed:true, backup:directory, credentialState:'pending-app-migration'};
}

export function restoreSettings(settingsPath, backupDirectory) {
  const record = readJson(path.join(backupDirectory, 'changes.json'));
  if (path.resolve(record.settingsPath).toLowerCase() !== path.resolve(settingsPath).toLowerCase()) throw new Error('Backup belongs to a different settings file.');
  const raw = fs.readFileSync(settingsPath);
  const data = readSettings(settingsPath);
  for (const key of keys) {
    if (data.app_config[key] !== record.after[key] && !(secretKeys.includes(key) && !data.app_config[key]))
      throw new Error('A configured field has changed since setup; restore it manually: ' + key);
  }
  for (const key of keys) {
    if (record.before[key].exists) data.app_config[key] = record.before[key].value;
    else delete data.app_config[key];
  }
  atomicWrite(settingsPath, data, digest(raw));
  return {restored:true, note:'OS-vault credentials are not backed up. Re-enter previous API keys in the app if they were overwritten.'};
}

export function checkSettings(settingsPath, config) {
  const data = readSettings(settingsPath).app_config;
  const expected = targetSettings(config);
  const mismatches = keys.filter(k => !secretKeys.includes(k) && data[k] !== expected[k]);
  const secretsStaged = ['llm_api_key','stt_custom_api_key'].some(k => Boolean(data[k]));
  return {matches:mismatches.length===0, mismatches, secretsStaged,
    vaultVerification:'Not inspected; use both connection-test buttons in the app.'};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [action, settingsPath, configPath, backup] = process.argv.slice(2);
    let result;
    if (action === 'validate') { readSettings(settingsPath); result={valid:true}; }
    else if (action === 'apply') result=applySettings(settingsPath, readJson(configPath), backup);
    else if (action === 'restore') result=restoreSettings(settingsPath, backup);
    else if (action === 'check') result=checkSettings(settingsPath, readJson(configPath));
    else throw new Error('Unknown settings operation.');
    console.log(JSON.stringify(result, null, 2));
    if (result.matches === false) process.exitCode=2;
  } catch(error) { console.error(error.message); process.exitCode=1; }
}
