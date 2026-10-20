import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

/** Tiny JSON-file store: installations, hashed single-use enrollment tokens, idempotency keys, nonces. */
export class Store {
  constructor(dir) {
    this.dir = dir;
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    this.file = path.join(dir, 'state.json');
    this.state = { installations: {}, tokens: {}, sent: {}, settings: { provider: null, recipient: null, pending: null } };
    if (fs.existsSync(this.file)) this.state = { ...this.state, ...JSON.parse(fs.readFileSync(this.file, 'utf8')) };
    this.state.settings ??= { provider: null, recipient: null, pending: null };
    this.nonces = new Map(); // in-memory; bounded by the timestamp window
  }
  save() {
    const tmp = this.file + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(this.state), { mode: 0o600 });
    fs.renameSync(tmp, this.file);
  }
  static hashToken(t) { return crypto.createHash('sha256').update(t).digest('hex'); }
  addToken(token, ttlMs = 24 * 3600e3, now = Date.now()) {
    this.state.tokens[Store.hashToken(token)] = { expires: now + ttlMs }; this.save();
  }
  consumeToken(token, now = Date.now()) {
    const h = Store.hashToken(token), t = this.state.tokens[h];
    if (!t) return false;
    delete this.state.tokens[h]; // single use, consumed even if expired
    this.save();
    return t.expires > now;
  }
  addInstallation(id, secret, deviceName, now = Date.now()) {
    this.state.installations[id] = { secret, deviceName, enrolledAt: now }; this.save();
  }
  getInstallation(id) { return Object.hasOwn(this.state.installations, id) ? this.state.installations[id] : null; }
  useNonce(id, nonce, now = Date.now()) {
    for (const [k, t] of this.nonces) if (now - t > 15 * 60e3) this.nonces.delete(k);
    const key = `${id}:${nonce}`;
    if (this.nonces.has(key)) return false;
    this.nonces.set(key, now); return true;
  }
  get settings() { return this.state.settings; }
  setProvider(p) { this.state.settings.provider = p; this.save(); }
  setPending(p) { this.state.settings.pending = p; this.save(); }
  setRecipient(r) { this.state.settings.recipient = r; this.state.settings.pending = null; this.save(); }
  /** Idempotency: returns the earlier result for a key, if any. */
  getSent(key) { return Object.hasOwn(this.state.sent, key) ? this.state.sent[key] : null; }
  markSent(key, result) { this.state.sent[key] = result; this.save(); }
}
