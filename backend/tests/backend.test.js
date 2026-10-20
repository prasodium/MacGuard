import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createApp } from '../src/server.js';
import { Store } from '../src/store.js';
import { sign } from '../src/auth.js';
import { ConsoleProvider, ProviderError, ResendProvider } from '../src/email/provider.js';
import { mapUrl, incidentEmail } from '../src/email/template.js';
import { RateLimiter } from '../src/ratelimit.js';

const config = { ownerEmail: 'owner@example.com', fromEmail: 'MacGuard <a@example.com>', maxBodyBytes: 16384,
  clockSkewSeconds: 300, rateLimitPerMinute: 100, enrollRateLimitPerHour: 100 };
const INC = '0b6f3a52-7a31-4c1a-9f0e-5d0c2f0a8b11';

async function boot(overrides = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mg-'));
  const store = new Store(dir);
  const provider = overrides.provider ?? new ConsoleProvider(() => {});
  const server = createApp({ config: { ...config, ...overrides.config }, store, provider });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const secret = crypto.randomBytes(32);
  store.addInstallation('inst-1', secret.toString('base64'), 'Test Mac');
  const call = async (p, body, { headers = {}, raw, skew = 0, nonce = crypto.randomUUID(), sigSecret = secret } = {}) => {
    const b = Buffer.from(raw ?? JSON.stringify(body));
    const ts = String(Math.floor(Date.now() / 1000) + skew);
    const h = { 'content-type': 'application/json', 'x-mg-installation': 'inst-1', 'x-mg-timestamp': ts, 'x-mg-nonce': nonce,
      'x-mg-signature': sign(sigSecret, 'POST', p, ts, nonce, b), ...headers };
    const r = await fetch(base + p, { method: 'POST', headers: h, body: b });
    return { status: r.status, json: await r.json() };
  };
  return { server, store, provider, base, call, secret, close: () => server.close() };
}

const incident = (o = {}) => ({ incidentId: INC, eventType: 'charger_disconnected', occurredAt: '2026-10-20T10:00:00Z', timeZone: 'Asia/Kolkata',
  device: { name: 'Test Mac', model: 'Mac14,2', osVersion: '27.0.1' }, powerBefore: 'connected', powerAfter: 'disconnected', batteryPercent: 80,
  alarmStatus: 'succeeded', screenLockStatus: 'inProgress', locationStatus: 'pending', location: null, isTest: false, ...o });

test('valid incident sends exactly one email to the configured owner only', async () => {
  const t = await boot();
  const r = await t.call('/v1/incidents', incident({ to: 'attacker@evil.com' }));
  assert.equal(r.status, 200);
  assert.equal(t.provider.sent.length, 1);
  assert.equal(t.provider.sent[0].to, 'owner@example.com');
  assert.match(t.provider.sent[0].subject, /MACGUARD ALERT: Unauthorized Charger Disconnection/);
  t.close();
});

test('duplicate incident (same id) does not send a second email', async () => {
  const t = await boot();
  await t.call('/v1/incidents', incident());
  const r = await t.call('/v1/incidents', incident());
  assert.equal(r.status, 200); assert.equal(r.json.duplicate, true);
  assert.equal(t.provider.sent.length, 1);
  t.close();
});

test('rejects bad signature, wrong secret, stale timestamp, and replayed nonce', async () => {
  const t = await boot();
  assert.equal((await t.call('/v1/incidents', incident(), { sigSecret: crypto.randomBytes(32) })).status, 401);
  assert.equal((await t.call('/v1/incidents', incident(), { skew: -1000 })).status, 401);
  assert.equal((await t.call('/v1/incidents', incident(), { nonce: 'n1' })).status, 200);
  assert.equal((await t.call('/v1/incidents/' + INC + '/status', { incidentId: INC, statusCode: 'alarm_silenced', monitoringState: 'healthy', timestamp: '2026-10-20T10:00:00Z' }, { nonce: 'n1' })).status, 401);
  assert.equal(t.provider.sent.length, 1);
  t.close();
});

test('unsigned request is rejected without detail', async () => {
  const t = await boot();
  const r = await fetch(t.base + '/v1/incidents', { method: 'POST', body: '{}' });
  assert.equal(r.status, 401);
  assert.deepEqual(await r.json(), { error: 'unauthorized' });
  t.close();
});

test('invalid coordinates and malformed payloads are rejected', async () => {
  const t = await boot();
  const bad = (loc) => t.call('/v1/incidents', incident({ location: loc, incidentId: INC }));
  const L = { latitude: 10, longitude: 20, accuracy: 5, acquiredAt: '2026-10-20T10:00:00Z', source: 'CoreLocation', freshness: 'fresh' };
  assert.equal((await bad({ ...L, latitude: 91 })).status, 400);
  assert.equal((await bad({ ...L, longitude: -181 })).status, 400);
  assert.equal((await bad({ ...L, latitude: 'x' })).status, 400);
  assert.equal((await bad({ ...L, freshness: 'live' })).status, 400);
  assert.equal((await t.call('/v1/incidents', null, { raw: 'not json' })).status, 400);
  assert.equal((await t.call('/v1/incidents', incident({ incidentId: 'nope' }))).status, 400);
  assert.equal(t.provider.sent.length, 0);
  t.close();
});

test('oversized body is rejected', async () => {
  const t = await boot();
  const r = await t.call('/v1/incidents', null, { raw: JSON.stringify({ pad: 'x'.repeat(20000) }) });
  assert.equal(r.status, 413);
  t.close();
});

test('location update and status are idempotent per sequence/code', async () => {
  const t = await boot();
  const loc = { incidentId: INC, sequence: 1, locationStatus: 'acquired', monitoringState: 'healthy', isFollowUp: false, sentAt: '2026-10-20T10:00:05Z',
    location: { latitude: 12.9, longitude: 77.6, accuracy: 8, acquiredAt: '2026-10-20T10:00:04Z', source: 'CoreLocation', freshness: 'fresh' } };
  await t.call(`/v1/incidents/${INC}/location`, loc);
  await t.call(`/v1/incidents/${INC}/location`, loc);
  await t.call(`/v1/incidents/${INC}/location`, { ...loc, sequence: 2, isFollowUp: true });
  assert.equal(t.provider.sent.length, 2);
  assert.match(t.provider.sent[0].html, /maps\.apple\.com\/\?ll=12\.900000,77\.600000/);
  assert.equal((await t.call(`/v1/incidents/${INC}/status`, { incidentId: INC, statusCode: 'hack', monitoringState: 'x', timestamp: '2026-10-20T10:00:00Z' })).status, 400);
  assert.equal((await t.call(`/v1/incidents/${INC}/location`, { ...loc, incidentId: '1b6f3a52-7a31-4c1a-9f0e-5d0c2f0a8b11' })).status, 400);
  t.close();
});

test('enrollment: single-use token, expired token, bad token', async () => {
  const t = await boot();
  t.store.addToken('tok-1');
  const body = (token, id) => JSON.stringify({ enrollmentToken: token, installationId: id, secret: crypto.randomBytes(32).toString('base64'), deviceName: 'M' });
  const post = (b) => fetch(t.base + '/v1/enroll', { method: 'POST', body: b });
  assert.equal((await post(body('tok-1', 'a'))).status, 201);
  assert.equal((await post(body('tok-1', 'b'))).status, 403);
  assert.equal((await post(body('wrong', 'c'))).status, 403);
  t.store.addToken('old', -1000);
  assert.equal((await post(body('old', 'd'))).status, 403);
  assert.equal((await post(JSON.stringify({ enrollmentToken: 'x', installationId: 'e', secret: 'AAAA' }))).status, 400);
  assert.ok(!fs.readFileSync(t.store.file, 'utf8').includes('tok-1'), 'tokens stored only as hashes');
  t.close();
});

test('provider rejection / outage returns generic error with no internals', async () => {
  const mk = (retryable) => ({ async send() { throw new ProviderError('secret-detail re_abc123', { retryable }); } });
  let t = await boot({ provider: mk(false) });
  let r = await t.call('/v1/incidents', incident());
  assert.equal(r.status, 502); assert.deepEqual(r.json, { error: 'provider_unavailable' }); t.close();
  t = await boot({ provider: mk(true) });
  r = await t.call('/v1/incidents', incident());
  assert.equal(r.status, 503); assert.ok(!JSON.stringify(r.json).includes('re_abc'));
  assert.equal(t.store.getSent(`incident:${INC}:initial`), null, 'failed sends are not marked sent, so retries work');
  t.close();
});

test('rate limiting per installation', async () => {
  const t = await boot({ config: { rateLimitPerMinute: 2 } });
  const s = [];
  for (let i = 0; i < 4; i++) s.push((await t.call('/v1/incidents/' + INC + '/status', { incidentId: INC, statusCode: 'alarm_silenced', monitoringState: 'h', timestamp: '2026-10-20T10:00:00Z' })).status);
  assert.deepEqual(s, [200, 200, 429, 429]);
  t.close();
});

test('RateLimiter windows reset', () => {
  const r = new RateLimiter(1, 1000);
  assert.ok(r.allow('k', 0)); assert.ok(!r.allow('k', 10)); assert.ok(r.allow('k', 1500));
});

test('map link only for valid coordinates; missing location is disclosed', () => {
  assert.equal(mapUrl(null), null);
  assert.equal(mapUrl({ latitude: 100, longitude: 0 }), null);
  assert.equal(mapUrl({ latitude: NaN, longitude: 0 }), null);
  assert.ok(mapUrl({ latitude: 1, longitude: 2 }).startsWith('https://maps.apple.com/'));
  const m = incidentEmail(incident());
  assert.match(m.html, /LOCATION UNAVAILABLE/); assert.ok(!m.html.includes('maps.apple.com')); assert.match(m.text, /LOCATION UNAVAILABLE/);
});

test('cached/last-known locations are labelled and never presented as live; html is escaped', () => {
  const loc = { latitude: 1, longitude: 2, accuracy: 30, acquiredAt: '2026-10-19T00:00:00Z', source: 'CoreLocation', freshness: 'lastKnown' };
  const m = incidentEmail(incident({ location: loc, device: { name: '<script>x</script>', model: null, osVersion: '27' } }));
  assert.match(m.html, /LAST KNOWN LOCATION/); assert.match(m.text, /NOT live/);
  assert.ok(!m.html.includes('<script>x'));
});

test('Resend provider sends bearer auth + idempotency key and hides error bodies', async () => {
  let seen;
  const ok = new ResendProvider({ apiKey: 'k', fetchImpl: async (u, o) => { seen = { u, o }; return { ok: true, json: async () => ({ id: 'abc' }) }; } });
  assert.deepEqual(await ok.send({ to: 't', from: 'f', subject: 's', html: 'h', text: 't', idempotencyKey: 'key1' }), { id: 'abc' });
  assert.equal(seen.u, 'https://api.resend.com/emails');
  assert.equal(seen.o.headers.Authorization, 'Bearer k'); assert.equal(seen.o.headers['Idempotency-Key'], 'key1');
  const bad = new ResendProvider({ apiKey: 'k', fetchImpl: async () => ({ ok: false, status: 422, json: async () => ({ message: 'leak' }) }) });
  await assert.rejects(() => bad.send({ idempotencyKey: 'x' }), (e) => e.retryable === false && !e.message.includes('leak'));
});

test('state file permissions are owner-only', async () => {
  const t = await boot(); t.store.save();
  assert.equal(fs.statSync(t.store.file).mode & 0o777, 0o600);
  t.close();
});
