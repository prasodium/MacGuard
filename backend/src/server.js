import http from 'node:http';
import { pathToFileURL } from 'node:url';
import { loadConfig } from './config.js';
import { Store } from './store.js';
import { verifyRequest } from './auth.js';
import { RateLimiter } from './ratelimit.js';
import crypto from 'node:crypto';
import { createProvider, ProviderError, UnconfiguredProvider, maskEmail } from './email/provider.js';
import { incidentEmail, locationEmail, statusEmail } from './email/template.js';
import * as V from './validate.js';

const ROUTE = /^\/v1\/incidents\/([^/]+)\/(location|status)$/;

export function createApp({ config, store, provider, now = () => Date.now(), fetchImpl }) {
  const limiter = new RateLimiter(config.rateLimitPerMinute, 60e3);
  const configLimiter = new RateLimiter(config.configRateLimitPerHour ?? 20, 3600e3);
  const codeLimiter = new RateLimiter(3, 3600e3); // verification codes per target address per hour
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

  /** Provider/sender saved from the app win over environment defaults. Keys never leave the backend. */
  const activeProvider = () => {
    const sp = store.settings.provider;
    return sp ? createProvider({ emailProvider: sp.name, brevoApiKey: sp.apiKey, resendApiKey: sp.apiKey }, { fetchImpl }) : provider;
  };
  const activeFrom = () => store.settings.provider?.fromEmail || config.fromEmail;
  /** Verified recipient chosen in the app, else the operator's OWNER_EMAIL. Never client-supplied per request. */
  const activeRecipient = () => store.settings.recipient?.email || config.ownerEmail || null;

  class NoRecipient extends Error {}

  async function deliver(idKey, mail) {
    const prior = store.getSent(idKey);
    if (prior) return { status: 'accepted', providerId: prior.providerId, duplicate: true };
    const to = activeRecipient();
    if (!to) throw new NoRecipient();
    if (!activeFrom()) throw new NoRecipient();
    const r = await activeProvider().send({ to, from: activeFrom(), idempotencyKey: idKey, ...mail });
    store.markSent(idKey, { providerId: r.id, at: now() });
    return { status: 'accepted', providerId: r.id, duplicate: false };
  }

  const hashCode = (code, email, salt) => crypto.createHash('sha256').update(`${salt}:${email}:${code}`).digest('hex');

  async function handleConfig(p, parse, inst, res) {
    if (!configLimiter.allow(inst, now())) return json(res, 429, { error: 'rate_limited' });
    if (p === '/v1/config/provider') {
      const c = V.validateProviderConfig(parse());
      const candidate = createProvider({ emailProvider: c.provider, brevoApiKey: c.apiKey, resendApiKey: c.apiKey }, { fetchImpl });
      try { await candidate.verify?.(); }
      catch (e) { if (e instanceof ProviderError) return json(res, e.retryable ? 503 : 400, { error: e.retryable ? 'provider_unavailable' : 'provider_key_rejected' }); throw e; }
      store.setProvider({ name: c.provider, apiKey: c.apiKey, fromEmail: c.fromEmail });
      return json(res, 200, { provider: c.provider, fromEmail: maskEmail(c.fromEmail) });
    }
    if (p === '/v1/config/recipient/request') {
      const { email } = V.validateRecipientRequest(parse());
      if (!activeFrom()) return json(res, 409, { error: 'provider_not_configured' });
      if (!codeLimiter.allow(email, now())) return json(res, 429, { error: 'rate_limited' });
      const code = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
      const salt = crypto.randomBytes(8).toString('hex');
      try {
        await activeProvider().send({ to: email, from: activeFrom(), idempotencyKey: `verify:${email}:${now()}`,
          subject: 'MacGuard: your verification code',
          text: `Your MacGuard verification code is ${code}. It expires in 15 minutes.\nIf you did not request this, ignore this email.`,
          html: `<p>Your MacGuard verification code is <b style="font-size:20px;letter-spacing:2px">${code}</b>.</p><p>It expires in 15 minutes. If you did not request this, ignore this email.</p>` });
      } catch (e) { if (e instanceof ProviderError) return json(res, e.retryable ? 503 : 502, { error: 'provider_unavailable' }); throw e; }
      store.setPending({ email, salt, codeHash: hashCode(code, email, salt), expires: now() + 15 * 60e3, attempts: 0 });
      return json(res, 200, { status: 'code_sent', recipient: maskEmail(email) });
    }
    if (p === '/v1/config/recipient/confirm') {
      const { email, code } = V.validateRecipientConfirm(parse());
      const pend = store.settings.pending;
      if (!pend || pend.email !== email || pend.expires < now() || pend.attempts >= 5) return json(res, 400, { error: 'code_invalid' });
      pend.attempts += 1; store.setPending(pend);
      const given = Buffer.from(hashCode(code, email, pend.salt), 'hex'), want = Buffer.from(pend.codeHash, 'hex');
      if (!crypto.timingSafeEqual(given, want)) return json(res, 400, { error: 'code_invalid' });
      const old = store.settings.recipient?.email || config.ownerEmail || null;
      store.setRecipient({ email, verifiedAt: now() });
      if (old && old !== email) { // tell the previous address so a hijacked change is visible
        activeProvider().send({ to: old, from: activeFrom(), idempotencyKey: `changed:${email}:${now()}`, subject: 'MacGuard: alert recipient changed',
          text: `MacGuard alert emails now go to ${maskEmail(email)}. If this was not you, rotate your enrollment and review your backend.`,
          html: `<p>MacGuard alert emails now go to <b>${maskEmail(email)}</b>.</p><p>If this was not you, rotate your enrollment and review your backend.</p>` }).catch(() => {});
      }
      return json(res, 200, { status: 'verified', recipient: maskEmail(email) });
    }
    return json(res, 404, { error: 'not_found' });
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

      if (p === '/v1/info') {
        // Lets the app show which delivery method/recipient the backend uses. Never returns keys.
        const rcp = activeRecipient(), pend = store.settings.pending;
        return json(res, 200, { provider: store.settings.provider?.name ?? provider.name ?? 'unknown',
          fromEmail: activeFrom() ? maskEmail(activeFrom().replace(/^.*<|>$/g, '')) : null,
          recipient: rcp ? maskEmail(rcp) : null, recipientVerified: !!rcp,
          pendingRecipient: pend && pend.expires > now() ? maskEmail(pend.email) : null, version: 2 });
      }
      if (p.startsWith('/v1/config/')) return await handleConfig(p, parse, inst, res);
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
      if (e instanceof NoRecipient) return json(res, 409, { error: 'no_verified_recipient' });
      if (e instanceof ProviderError && e.notConfigured) return json(res, 409, { error: 'provider_not_configured' });
      if (e instanceof ProviderError) return json(res, e.retryable ? 503 : 502, { error: 'provider_unavailable' });
      console.error('internal error', e?.name); // never log request headers/tokens
      return json(res, 500, { error: 'internal' });
    }
  }

  return http.createServer((req, res) => { handle(req, res).catch(() => { if (!res.headersSent) json(res, 500, { error: 'internal' }); }); });
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const config = loadConfig();
  let provider;
  try { provider = createProvider(config); } catch (e) { console.warn(`Email provider not ready (${e.message}); configure it from the app or set the env key.`); provider = new UnconfiguredProvider(config.emailProvider); }
  createApp({ config, store: new Store(config.dataDir), provider }).listen(config.port, () => console.log(`MacGuard backend on :${config.port}`));
}
