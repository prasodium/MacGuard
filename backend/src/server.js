import http from 'node:http';
import { pathToFileURL } from 'node:url';
import { loadConfig } from './config.js';
import { Store } from './store.js';
import { verifyRequest } from './auth.js';
import { RateLimiter } from './ratelimit.js';
import { ResendProvider, ConsoleProvider, ProviderError } from './email/provider.js';
import { incidentEmail, locationEmail, statusEmail } from './email/template.js';
import * as V from './validate.js';

const ROUTE = /^\/v1\/incidents\/([^/]+)\/(location|status)$/;

export function createApp({ config, store, provider, now = () => Date.now() }) {
  const limiter = new RateLimiter(config.rateLimitPerMinute, 60e3);
  const enrollLimiter = new RateLimiter(config.enrollRateLimitPerHour, 3600e3);

  const json = (res, status, obj) => {
    const b = JSON.stringify(obj);
    res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
    res.end(b);
  };

  async function readBody(req) {
    const chunks = []; let n = 0;
    for await (const c of req) { n += c.length; if (n > config.maxBodyBytes) { const e = new Error('too large'); e.code = 413; throw e; } chunks.push(c); }
    return Buffer.concat(chunks);
  }

  async function deliver(idKey, mail) {
    const prior = store.getSent(idKey);
    if (prior) return { status: 'accepted', providerId: prior.providerId, duplicate: true };
    const r = await provider.send({ to: config.ownerEmail, from: config.fromEmail, idempotencyKey: idKey, ...mail });
    store.markSent(idKey, { providerId: r.id, at: now() });
    return { status: 'accepted', providerId: r.id, duplicate: false };
  }

  async function handle(req, res) {
    const url = new URL(req.url, 'http://x');
    const p = url.pathname;
    if (req.method === 'GET' && p === '/healthz') return json(res, 200, { ok: true });
    if (req.method !== 'POST') return json(res, 404, { error: 'not_found' });

    let body;
    try { body = await readBody(req); } catch (e) { return json(res, e.code === 413 ? 413 : 400, { error: 'bad_request' }); }
    let data;
    const parse = () => { try { return JSON.parse(body.toString('utf8')); } catch { throw new V.ValidationError('json'); } };

    try {
      if (p === '/v1/enroll') {
        if (!enrollLimiter.allow(req.socket.remoteAddress ?? 'x', now())) return json(res, 429, { error: 'rate_limited' });
        const e = V.validateEnroll(parse());
        if (!store.consumeToken(e.enrollmentToken, now())) return json(res, 403, { error: 'invalid_token' });
        store.addInstallation(e.installationId, e.secret, e.deviceName, now());
        return json(res, 201, { status: 'enrolled' });
      }

      const auth = verifyRequest({ store, headers: req.headers, method: req.method, path: p, body, now: now(), skewSeconds: config.clockSkewSeconds });
      if (!auth.ok) return json(res, 401, { error: 'unauthorized' }); // no detail: don't help attackers
      const inst = req.headers['x-mg-installation'];
      if (!limiter.allow(inst, now())) return json(res, 429, { error: 'rate_limited' });

      if (p === '/v1/incidents') {
        data = V.validateIncident(parse());
        if (data.eventType === 'test') return json(res, 400, { error: 'use_test_endpoint' });
        return json(res, 200, await deliver(`incident:${data.incidentId}:initial`, incidentEmail(data)));
      }
      if (p === '/v1/test-email') {
        data = V.validateIncident({ ...parse(), eventType: 'test' });
        // Test mails are intentionally not idempotent across user-initiated sends.
        const key = `test:${inst}:${Math.floor(now() / 1000)}`;
        return json(res, 200, await deliver(key, incidentEmail(data)));
      }
      const m = ROUTE.exec(p);
      if (m && V.isIncidentId(m[1])) {
        if (m[2] === 'location') {
          data = V.validateLocationUpdate(parse(), m[1]);
          return json(res, 200, await deliver(`incident:${m[1]}:location:${data.sequence}`, locationEmail(data)));
        }
        data = V.validateStatus(parse(), m[1]);
        return json(res, 200, await deliver(`incident:${m[1]}:status:${data.statusCode}`, statusEmail(data)));
      }
      return json(res, 404, { error: 'not_found' });
    } catch (e) {
      if (e instanceof V.ValidationError) return json(res, 400, { error: 'invalid_payload' });
      if (e instanceof ProviderError) return json(res, e.retryable ? 503 : 502, { error: 'provider_unavailable' });
      console.error('internal error', e?.name); // never log request headers/tokens
      return json(res, 500, { error: 'internal' });
    }
  }

  return http.createServer((req, res) => { handle(req, res).catch(() => { if (!res.headersSent) json(res, 500, { error: 'internal' }); }); });
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const config = loadConfig();
  const provider = config.emailProvider === 'console' ? new ConsoleProvider() : (() => {
    if (!config.resendApiKey) throw new Error('RESEND_API_KEY required for provider "resend"');
    return new ResendProvider({ apiKey: config.resendApiKey });
  })();
  createApp({ config, store: new Store(config.dataDir), provider }).listen(config.port, () => console.log(`MacGuard backend on :${config.port}`));
}
