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
  const server = createApp({ config: { ...config, ...overrides.config }, store, provider, fetchImpl: overrides.fetchImpl, now: overrides.now });
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

import { BrevoProvider, parseFrom, createProvider, maskEmail } from '../src/email/provider.js';

test('Brevo provider sends api-key header and Brevo body shape; hides error bodies', async () => {
  let seen;
  const ok = new BrevoProvider({ apiKey: 'bk', fetchImpl: async (u, o) => { seen = { u, o, b: JSON.parse(o.body) }; return { ok: true, json: async () => ({ messageId: '<m1>' }) }; } });
  assert.deepEqual(await ok.send({ to: 'o@x.com', from: 'MacGuard <a@b.com>', subject: 's', html: 'h', text: 't' }), { id: '<m1>' });
  assert.equal(seen.u, 'https://api.brevo.com/v3/smtp/email'); // default base URL
  assert.equal(seen.o.headers['api-key'], 'bk');
  assert.deepEqual(seen.b.sender, { name: 'MacGuard', email: 'a@b.com' });
  assert.deepEqual(seen.b.to, [{ email: 'o@x.com' }]);
  assert.equal(seen.b.htmlContent, 'h'); assert.equal(seen.b.textContent, 't');
  const bad = new BrevoProvider({ apiKey: 'bk', fetchImpl: async () => ({ ok: false, status: 401, json: async () => ({ message: 'leak' }) }) });
  await assert.rejects(() => bad.send({ to: 'a', from: 'a@b.c', subject: 's' }), (e) => e.retryable === false && !e.message.includes('leak'));
  const down = new BrevoProvider({ apiKey: 'bk', fetchImpl: async () => ({ ok: false, status: 503 }) });
  await assert.rejects(() => down.send({ to: 'a', from: 'a@b.c', subject: 's' }), (e) => e.retryable === true);
});

test('parseFrom, createProvider selection and key requirements', () => {
  assert.deepEqual(parseFrom('a@b.com'), { email: 'a@b.com' });
  assert.deepEqual(parseFrom('"My App" <a@b.com>'), { name: 'My App', email: 'a@b.com' });
  assert.equal(createProvider({ emailProvider: 'console' }).name, 'console');
  assert.equal(createProvider({ emailProvider: 'brevo', brevoApiKey: 'k' }).name, 'brevo');
  assert.equal(createProvider({ emailProvider: 'resend', resendApiKey: 'k' }).name, 'resend');
  assert.throws(() => createProvider({ emailProvider: 'brevo' }), /BREVO_API_KEY/);
  assert.throws(() => createProvider({ emailProvider: 'resend' }), /RESEND_API_KEY/);
  assert.throws(() => createProvider({ emailProvider: 'smtp' }), /Unknown EMAIL_PROVIDER/);
});

test('/v1/info reports method and masked recipient, requires auth, never leaks keys', async () => {
  const t = await boot();
  const r = await t.call('/v1/info', {});
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { provider: 'console', fromEmail: 'a***@example.com', recipient: 'o***@example.com', recipientVerified: true, pendingRecipient: null, version: 2 });
  const un = await fetch(t.base + '/v1/info', { method: 'POST', body: '{}' });
  assert.equal(un.status, 401);
  assert.equal(maskEmail('owner@example.com'), 'o***@example.com');
  t.close();
});

// ---- in-app configuration: Brevo key + verified recipient ----
const brevoFetch = (log = [], { accountOk = true, sendOk = true } = {}) => async (url, o) => {
  log.push({ url, o });
  if (url.endsWith('/v3/account')) return { ok: accountOk, status: accountOk ? 200 : 401, json: async () => ({}) };
  return { ok: sendOk, status: sendOk ? 201 : 400, json: async () => ({ messageId: '<id>' }) };
};
const lastCode = (log) => /code is (\d{6})/.exec(JSON.parse(log.filter((l) => l.url.endsWith('/smtp/email')).at(-1).o.body).textContent)[1];
const bare = { ownerEmail: '', fromEmail: '' };

test('save Brevo key from the app: key verified, stored only on backend, never echoed', async () => {
  const log = []; const t = await boot({ config: bare, provider: { name: 'brevo', send: async () => { throw new Error('env provider must not be used'); } }, fetchImpl: brevoFetch(log) });
  const r = await t.call('/v1/config/provider', { provider: 'brevo', apiKey: 'xkeysib-secretsecret123', fromEmail: 'Me@Example.com' });
  assert.equal(r.status, 200); assert.deepEqual(r.json, { provider: 'brevo', fromEmail: 'M***@example.com'.replace('M', 'm') });
  assert.ok(log[0].url.endsWith('/v3/account') && log[0].o.headers['api-key'] === 'xkeysib-secretsecret123');
  assert.ok(!JSON.stringify(r.json).includes('secretsecret'));
  const info = await t.call('/v1/info', {});
  assert.ok(!JSON.stringify(info.json).includes('secretsecret')); assert.equal(info.json.provider, 'brevo');
  assert.equal(fs.statSync(t.store.file).mode & 0o777, 0o600);
  t.close();
});

test('rejected Brevo key is not saved; malformed config is 400', async () => {
  const t = await boot({ config: bare, fetchImpl: brevoFetch([], { accountOk: false }) });
  const r = await t.call('/v1/config/provider', { provider: 'brevo', apiKey: 'xkeysib-badbadbad123', fromEmail: 'a@b.com' });
  assert.equal(r.status, 400); assert.equal(r.json.error, 'provider_key_rejected'); assert.equal(t.store.settings.provider, null);
  for (const bad of [{ provider: 'smtp', apiKey: 'xkeysib-1234567890', fromEmail: 'a@b.com' }, { provider: 'brevo', apiKey: 'short', fromEmail: 'a@b.com' },
    { provider: 'brevo', apiKey: 'xkeysib-1234567890', fromEmail: 'not-an-email' }, { provider: 'brevo', apiKey: 'has space 1234567890', fromEmail: 'a@b.com' }])
    assert.equal((await t.call('/v1/config/provider', bad)).status, 400);
  t.close();
});

test('recipient must be verified with an emailed code before alerts go there', async () => {
  const log = []; const t = await boot({ config: bare, fetchImpl: brevoFetch(log) });
  await t.call('/v1/config/provider', { provider: 'brevo', apiKey: 'xkeysib-1234567890', fromEmail: 'sender@example.com' });
  // No verified recipient yet: alerts are refused rather than sent anywhere.
  assert.equal((await t.call('/v1/incidents', incident())).status, 409);
  const req = await t.call('/v1/config/recipient/request', { email: 'Me@Gmail.com' });
  assert.equal(req.status, 200); assert.equal(req.json.recipient, 'm***@gmail.com');
  const sent = JSON.parse(log.filter((l) => l.url.endsWith('/smtp/email')).at(-1).o.body);
  assert.deepEqual(sent.to, [{ email: 'me@gmail.com' }]);
  let info = (await t.call('/v1/info', {})).json;
  assert.equal(info.recipientVerified, false); assert.equal(info.pendingRecipient, 'm***@gmail.com');
  assert.equal((await t.call('/v1/incidents', incident())).status, 409, 'pending (unverified) address must not receive alerts');
  const code = lastCode(log);
  assert.equal((await t.call('/v1/config/recipient/confirm', { email: 'me@gmail.com', code: code === '000000' ? '111111' : '000000' })).status, 400);
  assert.equal((await t.call('/v1/config/recipient/confirm', { email: 'other@gmail.com', code })).status, 400);
  assert.equal((await t.call('/v1/config/recipient/confirm', { email: 'me@gmail.com', code })).status, 200);
  info = (await t.call('/v1/info', {})).json; assert.equal(info.recipientVerified, true); assert.equal(info.recipient, 'm***@gmail.com');
  assert.equal((await t.call('/v1/incidents', incident())).status, 200);
  const alert = JSON.parse(log.filter((l) => l.url.endsWith('/smtp/email')).at(-1).o.body);
  assert.deepEqual(alert.to, [{ email: 'me@gmail.com' }]); assert.deepEqual(alert.sender, { email: 'sender@example.com' });
  assert.ok(!fs.readFileSync(t.store.file, 'utf8').includes(code), 'code stored only as a hash');
  t.close();
});

test('code is single-use, expires, and is locked after 5 wrong attempts', async () => {
  let clock = Date.now(); const log = [];
  const t = await boot({ config: { ...bare, clockSkewSeconds: 100000 }, fetchImpl: brevoFetch(log), now: () => clock });
  await t.call('/v1/config/provider', { provider: 'brevo', apiKey: 'xkeysib-1234567890', fromEmail: 'sender@example.com' });
  await t.call('/v1/config/recipient/request', { email: 'a@gmail.com' });
  const code = lastCode(log);
  clock += 16 * 60e3;
  assert.equal((await t.call('/v1/config/recipient/confirm', { email: 'a@gmail.com', code })).status, 400, 'expired');
  await t.call('/v1/config/recipient/request', { email: 'a@gmail.com' }); const code2 = lastCode(log);
  const wrong = code2 === '123456' ? '654321' : '123456';
  for (let i = 0; i < 5; i++) await t.call('/v1/config/recipient/confirm', { email: 'a@gmail.com', code: wrong });
  assert.equal((await t.call('/v1/config/recipient/confirm', { email: 'a@gmail.com', code: code2 })).status, 400, 'locked after 5 attempts');
  t.close();
});

test('changing the recipient notifies the previous address; env OWNER_EMAIL counts as the previous one', async () => {
  const log = []; const t = await boot({ config: { ownerEmail: 'old@example.com', fromEmail: 'sender@example.com' }, fetchImpl: brevoFetch(log) });
  await t.call('/v1/config/provider', { provider: 'brevo', apiKey: 'xkeysib-1234567890', fromEmail: 'sender@example.com' });
  await t.call('/v1/config/recipient/request', { email: 'new@gmail.com' });
  await t.call('/v1/config/recipient/confirm', { email: 'new@gmail.com', code: lastCode(log) });
  await new Promise((r) => setTimeout(r, 20));
  const mails = log.filter((l) => l.url.endsWith('/smtp/email')).map((l) => JSON.parse(l.o.body));
  const notice = mails.find((m) => /recipient changed/.test(m.subject));
  assert.deepEqual(notice.to, [{ email: 'old@example.com' }]); assert.match(notice.textContent, /n\*\*\*@gmail\.com/);
  t.close();
});

test('config endpoints require signed requests, are rate limited, and code requests are capped per address', async () => {
  const log = []; const t = await boot({ config: { ...bare, configRateLimitPerHour: 100 }, fetchImpl: brevoFetch(log) });
  const un = await fetch(t.base + '/v1/config/provider', { method: 'POST', body: '{}' });
  assert.equal(un.status, 401);
  await t.call('/v1/config/provider', { provider: 'brevo', apiKey: 'xkeysib-1234567890', fromEmail: 'sender@example.com' });
  const st = [];
  for (let i = 0; i < 4; i++) st.push((await t.call('/v1/config/recipient/request', { email: 'spam@gmail.com' })).status);
  assert.deepEqual(st, [200, 200, 200, 429]);
  const t2 = await boot({ config: { ...bare, configRateLimitPerHour: 2 }, fetchImpl: brevoFetch([]) });
  const s2 = []; for (let i = 0; i < 3; i++) s2.push((await t2.call('/v1/config/provider', { provider: 'brevo', apiKey: 'xkeysib-1234567890', fromEmail: 'a@b.com' })).status);
  assert.deepEqual(s2, [200, 200, 429]);
  t.close(); t2.close();
});

test('recipient request without a configured sender is refused', async () => {
  const t = await boot({ config: bare });
  assert.equal((await t.call('/v1/config/recipient/request', { email: 'a@gmail.com' })).status, 409);
  t.close();
});

test('CONFIG_RATE_LIMIT_PER_HOUR=0 disables in-app configuration entirely', async () => {
  const log = []; const t = await boot({ config: { ...bare, configRateLimitPerHour: 0 }, fetchImpl: brevoFetch(log) });
  const r = await t.call('/v1/config/provider', { provider: 'brevo', apiKey: 'xkeysib-1234567890', fromEmail: 'a@b.com' });
  assert.equal(r.status, 429); assert.equal(t.store.settings.provider, null); assert.equal(log.length, 0);
  assert.ok(!new RateLimiter(0, 1000).allow('k', 0));
  t.close();
});
