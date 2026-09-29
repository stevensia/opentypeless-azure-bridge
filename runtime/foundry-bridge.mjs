import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const execFileAsync = promisify(execFile);
export const VERSION = '0.1.0';
const LIMIT = 26 * 1024 * 1024;

export function validateProfile(config) {
  if (config.schemaVersion !== 1 || config.cloud !== 'AzureCloud') throw new Error('Only schema 1 / AzureCloud is supported.');
  if (!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(config.tenantId || '') || /^0{8}-0{4}-0{4}-0{4}-0{12}$/.test(config.tenantId)) throw new Error('A real tenant ID is required. Initialize your local profile first.');
  if (config.tokenResource !== 'https://cognitiveservices.azure.com/') throw new Error('Unexpected Azure token audience.');
  for (const key of ['azureEndpoint', 'polishEndpoint']) {
    const u = new URL(config[key]);
    if (u.protocol !== 'https:' || !/^[a-z0-9-]+\.(?:cognitiveservices|openai)\.azure\.com$/.test(u.hostname) ||
        u.port || u.username || u.password || u.search || u.hash || u.pathname !== '/') throw new Error('Expected an Azure resource HTTPS endpoint: ' + key);
  }
  if (!Number.isInteger(config.port) || config.port < 1024 || config.port > 65535) throw new Error('Invalid local port.');
  const speech = config.transcriptionDeployments;
  const polish = config.polishDeployments;
  if (!Array.isArray(speech) || !speech.length || !polish || Array.isArray(polish)) throw new Error('Deployment allowlists required.');
  for (const name of [...speech, ...Object.keys(polish)]) {
    if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/.test(name)) throw new Error('Invalid deployment name.');
  }
  if (!speech.includes(config.defaultModel) || !Object.hasOwn(polish, config.polishModel)) throw new Error('Default deployment must be in its allowlist.');
  for (const rule of Object.values(polish)) {
    if (!rule || !Number.isInteger(rule.minimumOutputTokens) || rule.minimumOutputTokens < 1 || rule.minimumOutputTokens > 8192) throw new Error('Invalid minimumOutputTokens.');
    if (rule.reasoningEffort !== undefined && !['none','minimal','low','medium','high','xhigh'].includes(rule.reasoningEffort)) throw new Error('Invalid reasoningEffort.');
  }
  if (!/^\d{4}-\d{2}-\d{2}(?:-preview)?$/.test(config.audioApiVersion || '')) throw new Error('Audio API version required.');
  return config;
}

export function azureTokenProvider(config, execute = execFileAsync) {
  let cached, pending;
  return async () => {
    if (cached && cached.expires > Date.now() + 300000) return cached.token;
    if (!pending) pending = (async () => {
      try {
        const { stdout } = await execute(config.powershellPath,
          ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
            path.join(config.installDir, 'Get-Token.ps1')],
          { windowsHide: true, timeout: 25000, maxBuffer: 1024 * 1024,
            env: { ...process.env, AZURE_CONFIG_DIR: config.azureConfigDir } });
        const result = JSON.parse(stdout);
        if (!result.accessToken || !result.expires_on) throw new Error('Token unavailable');
        cached = { token: result.accessToken, expires: Number(result.expires_on) * 1000 };
        return cached.token;
      } catch {
        const error = new Error('Azure sign-in expired or requires interaction. Run Sign-In.ps1 in the bridge directory.');
        error.status = 503;
        throw error;
      } finally { pending = null; }
    })();
    return pending;
  };
}

function sameSecret(a, b) {
  const aa = Buffer.from(a), bb = Buffer.from(b);
  return aa.length === bb.length && crypto.timingSafeEqual(aa, bb);
}

// Detect only known PCM16 WAV files whose samples are exactly zero.
// This is not a volume threshold: quiet speech and other formats are unaffected.
export function isDigitalSilenceWav(bytes) {
  if (bytes.length < 44 || bytes.toString('ascii', 0, 4) !== 'RIFF' || bytes.toString('ascii', 8, 12) !== 'WAVE') return false;
  let pcm16 = false, samples = null;
  for (let offset = 12; offset + 8 <= bytes.length;) {
    const type = bytes.toString('ascii', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    const begin = offset + 8, end = begin + size;
    if (end > bytes.length) return false;
    if (type === 'fmt ' && size >= 16) pcm16 = bytes.readUInt16LE(begin) === 1 && bytes.readUInt16LE(begin + 14) === 16;
    if (type === 'data') {
      if (samples !== null) return false;
      samples = bytes.subarray(begin, end);
    }
    offset = end + (size % 2);
  }
  return pcm16 && samples !== null && samples.length > 0 && samples.length % 2 === 0 && samples.every(byte => byte === 0);
}

export function createBridge({ config, getToken = azureTokenProvider(config), fetchImpl = fetch, log = () => {} }) {
  validateProfile(config);
  if (typeof config.localApiKey !== 'string' || config.localApiKey.length < 16) throw new Error('Local API key must contain at least 16 characters.');
  const defaultModel = config.defaultModel;
  const DEPLOYMENTS = new Set(config.transcriptionDeployments);
  const POLISH_DEPLOYMENTS = new Set(Object.keys(config.polishDeployments));
  const AZURE_ENDPOINT = config.azureEndpoint.replace(/\/$/, '');
  const POLISH_ENDPOINT = config.polishEndpoint.replace(/\/$/, '') + '/openai/v1/chat/completions';
  let lastUpstreamStatus = null;
  let lastDeployment = null;
  let lastAzureRequestId = null;
  let lastPolishDeployment = null, lastPolishStatus = null;
  const server = http.createServer(async (req, res) => {
    const started = Date.now();
    let deployment = null;
    function send(status, value) {
      if (res.headersSent || res.destroyed) return;
      const body = JSON.stringify(value);
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
      res.end(body);
      log(`${new Date().toISOString()} ${req.method} status=${status} deployment=${deployment || '-'} elapsedMs=${Date.now() - started}`);
    }
    try {
      const port = server.address()?.port;
      if (!['127.0.0.1:' + port, 'localhost:' + port].includes(req.headers.host))
        return send(403, { error: { message: 'Invalid host' } });
      if (req.headers.origin) return send(403, { error: { message: 'Browser origins are not allowed' } });
      if (req.method === 'GET' && req.url === '/health')
        return send(200, { service: 'OpenTypeless Foundry Bridge', version: VERSION,
          configHash: config.configHash || null,
          model: defaultModel, lastDeployment, lastUpstreamStatus, lastAzureRequestId,
          polishModel: config.polishModel, lastPolishDeployment, lastPolishStatus });
      if (!sameSecret(req.headers.authorization || '', 'Bearer ' + config.localApiKey))
        return send(401, { error: { message: 'Local API key required' } });
      if (req.method === 'GET' && req.url === '/v1/models')
        return send(200, { object: 'list', data: [...DEPLOYMENTS].map(id => ({ id, object: 'model', owned_by: 'azure' })) });
      if (req.method === 'GET' && req.url === '/polish/v1/models')
        return send(200, { object: 'list', data: [...POLISH_DEPLOYMENTS].map(id => ({ id, object: 'model', owned_by: 'azure' })) });
      if (req.method === 'POST' && req.url === '/polish/v1/chat/completions') {
        if (!String(req.headers['content-type'] || '').startsWith('application/json'))
          return send(415, { error: { message: 'application/json required' } });
        if (Number(req.headers['content-length']) > 1024 * 1024)
          return send(413, { error: { message: 'Polish request too large' } });
        const chunks = []; let size = 0;
        for await (const chunk of req) {
          size += chunk.length;
          if (size > 1024 * 1024) return send(413, { error: { message: 'Polish request too large' } });
          chunks.push(chunk);
        }
        let incoming;
        try { incoming = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
        catch { return send(400, { error: { message: 'Invalid JSON' } }); }
        if (!incoming || !POLISH_DEPLOYMENTS.has(incoming.model) || !Array.isArray(incoming.messages) || !incoming.messages.length)
          return send(400, { error: { message: 'Supported polish deployment and messages required' } });
        deployment = incoming.model;
        const body = { model: deployment, messages: incoming.messages, stream: incoming.stream === true };
        const maxTokens = incoming.max_completion_tokens ?? incoming.max_tokens ?? 4096;
        if (!Number.isInteger(maxTokens) || maxTokens < 1 || maxTokens > 8192)
          return send(400, { error: { message: 'Token limit must be between 1 and 8192' } });
        // OpenTypeless connection tests request one token; GPT-5.2 can reject that
        // before producing a valid completion. Use a small compatible lower bound.
        const rule = config.polishDeployments[deployment];
        body.max_completion_tokens = Math.max(rule.minimumOutputTokens, maxTokens);
        // Preserve the app's own instructions; only adapt protocol parameters.
        if (rule.reasoningEffort !== undefined) body.reasoning_effort = rule.reasoningEffort;
        else if (typeof incoming.temperature === 'number') body.temperature = incoming.temperature;
        const controller = new AbortController();
        res.once('close', () => { if (!res.writableEnded) controller.abort(); });
        const token = await getToken();
        const upstream = await fetchImpl(POLISH_ENDPOINT, { method: 'POST',
          headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
          body: JSON.stringify(body), redirect: 'error',
          signal: AbortSignal.any([controller.signal, AbortSignal.timeout(55000)]) });
        lastPolishDeployment = deployment; lastPolishStatus = upstream.status;
        if (!upstream.ok) {
          let detail; try { detail = await upstream.json(); } catch { detail = {}; }
          return send(upstream.status, { error: { code: detail.error?.code || 'AzureError',
            message: String(detail.error?.message || 'Azure text request failed').slice(0, 1200) } });
        }
        if (body.stream) {
          if (!upstream.headers.get('content-type')?.includes('text/event-stream'))
            return send(502, { error: { message: 'Azure did not return the expected text stream' } });
          res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8',
            'Cache-Control': 'no-cache, no-store', 'X-Accel-Buffering': 'no' });
          await pipeline(Readable.fromWeb(upstream.body), res);
          log(`${new Date().toISOString()} POST polish status=200 deployment=${deployment} elapsedMs=${Date.now() - started}`);
          return;
        }
        let result; try { result = await upstream.json(); }
        catch { return send(502, { error: { message: 'Azure returned invalid JSON' } }); }
        if (!Array.isArray(result.choices)) return send(502, { error: { message: 'Azure returned an invalid completion' } });
        return send(200, result);
      }
      if (req.method !== 'POST' || req.url !== '/v1/audio/transcriptions')
        return send(404, { error: { message: 'Only audio transcriptions are supported' } });
      if (!String(req.headers['content-type'] || '').startsWith('multipart/form-data;'))
        return send(415, { error: { message: 'multipart/form-data required' } });
      if (Number(req.headers['content-length']) > LIMIT)
        return send(413, { error: { message: 'Audio upload too large' } });
      let size = 0;
      const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > LIMIT) return send(413, { error: { message: 'Audio upload too large' } });
        chunks.push(chunk);
      }
      let incoming;
      try {
        incoming = await new Request('http://127.0.0.1/', { method: 'POST',
          headers: { 'Content-Type': req.headers['content-type'] }, body: Buffer.concat(chunks) }).formData();
      } catch { return send(400, { error: { message: 'Invalid multipart upload' } }); }
      deployment = incoming.get('model');
      if (typeof deployment !== 'string' || !DEPLOYMENTS.has(deployment)) {
        deployment = null;
        return send(400, { error: { message: 'Unsupported Azure deployment. Choose a model from /v1/models.' } });
      }
      const file = incoming.get('file');
      if (!(file instanceof Blob) || file.size === 0 || file.size > 25 * 1024 * 1024)
        return send(400, { error: { message: 'A nonempty audio file under 25 MB is required' } });
      const digitalSilence = isDigitalSilenceWav(Buffer.from(await file.arrayBuffer()));
      const form = new FormData();
      form.set('model', deployment);
      form.set('file', file, 'audio.wav');
      form.set('response_format', 'json');
      for (const field of ['language', 'prompt', 'temperature']) {
        const value = incoming.get(field);
        if (typeof value === 'string' && value.length <= 16000) form.set(field, value);
      }
      // OpenTypeless custom Whisper has no prompt field. Add relevant local context
      // only when the client did not provide its own, using Azure's documented fields.
      if (!form.has('language') && config.defaultLanguage) form.set('language', config.defaultLanguage);
      if (digitalSilence) form.delete('prompt');
      else if (!form.has('prompt') && config.transcriptionPrompt) form.set('prompt', config.transcriptionPrompt);
      const token = await getToken();
      const upstreamUrl = `${AZURE_ENDPOINT}/openai/deployments/${encodeURIComponent(deployment)}/audio/transcriptions?api-version=${config.audioApiVersion}`;
      const upstream = await fetchImpl(upstreamUrl, { method: 'POST',
        headers: { Authorization: 'Bearer ' + token }, body: form,
        signal: AbortSignal.timeout(55000), redirect: 'error' });
      lastUpstreamStatus = upstream.status;
      lastDeployment = deployment;
      lastAzureRequestId = upstream.headers.get('apim-request-id') || upstream.headers.get('x-request-id');
      let result;
      try { result = await upstream.json(); }
      catch { return send(502, { error: { message: 'Azure returned an unexpected response' } }); }
      if (!upstream.ok) return send(upstream.status, { error: {
        code: result.error?.code || 'AzureError',
        message: String(result.error?.message || 'Azure request failed').slice(0, 1200) } });
      if (typeof result.text !== 'string')
        return send(502, { error: { message: 'Azure response has no transcription text' } });
      // Still call Azure and check its status, so the app's silent connection test
      // verifies authentication and deployment availability rather than just localhost.
      send(200, { text: digitalSilence ? '' : result.text });
    } catch (error) {
      send(error.status || 502, { error: { message: error.status ? error.message : 'Azure connection failed or timed out' } });
    }
  });
  server.requestTimeout = 90000;
  server.headersTimeout = 15000;
  return server;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const directory = path.dirname(fileURLToPath(import.meta.url));
  const raw = fs.readFileSync(path.join(directory, 'bridge-config.json'));
  const config = JSON.parse(raw.toString('utf8').replace(/^\uFEFF/, ''));
  config.configHash = crypto.createHash('sha256').update(raw).digest('hex');
  const logPath = path.join(directory, 'bridge.log');
  const log = line => {
    if (fs.existsSync(logPath) && fs.statSync(logPath).size > 1024 * 1024) fs.renameSync(logPath, logPath + '.1');
    fs.appendFileSync(logPath, line + '\n');
  };
  const server = createBridge({ config, log });
  server.on('error', error => { log(`Server error: ${error.code || 'unknown'}`); process.exitCode = 1; });
  server.listen(config.port, '127.0.0.1', () => log(`Listening on 127.0.0.1:${config.port}; version=${VERSION}; defaultModel=${config.defaultModel || 'gpt-4o-transcribe'}`));
}
