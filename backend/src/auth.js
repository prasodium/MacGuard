import crypto from 'node:crypto';

export const sha256hex = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

export function canonical(method, path, ts, nonce, body) {
  return [method.toUpperCase(), path, ts, nonce, sha256hex(body)].join('\n');
}

export function sign(secretBytes, method, path, ts, nonce, body) {
  return crypto.createHmac('sha256', secretBytes).update(canonical(method, path, ts, nonce, body)).digest('hex');
}

/** Verifies an HMAC-signed request. Returns {ok:true, installation} or {ok:false, reason}. */
export function verifyRequest({ store, headers, method, path, body, now = Date.now(), skewSeconds = 300 }) {
  const id = headers['x-mg-installation'], ts = headers['x-mg-timestamp'],
    nonce = headers['x-mg-nonce'], sig = headers['x-mg-signature'];
  if (!id || !ts || !nonce || !sig || nonce.length > 64 || !/^\d{9,12}$/.test(ts)) return { ok: false, reason: 'missing' };
  if (Math.abs(now / 1000 - Number(ts)) > skewSeconds) return { ok: false, reason: 'stale' };
  const inst = store.getInstallation(id);
  if (!inst) return { ok: false, reason: 'unknown' };
  const expected = Buffer.from(sign(Buffer.from(inst.secret, 'base64'), method, path, ts, nonce, body), 'hex');
  let given; try { given = Buffer.from(sig, 'hex'); } catch { return { ok: false, reason: 'bad' }; }
  if (given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) return { ok: false, reason: 'bad' };
  if (!store.useNonce(id, nonce, now)) return { ok: false, reason: 'replay' }; // only after a valid signature
  return { ok: true, installation: inst };
}
