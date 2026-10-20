/** Provider abstraction: any provider implements send({to,from,subject,html,text,idempotencyKey}). */
export class ProviderError extends Error {
  constructor(message, { retryable, notConfigured = false }) { super(message); this.retryable = retryable; this.notConfigured = notConfigured; }
}

/** Placeholder until an API key is provided via env or from the app. */
export class UnconfiguredProvider {
  constructor(name) { this.name = name; }
  async send() { throw new ProviderError('provider not configured', { retryable: false, notConfigured: true }); }
}

export class ResendProvider {
  name = 'resend';
  constructor({ apiKey, fetchImpl }) { this.apiKey = apiKey; this.fetch = fetchImpl ?? fetch; }
  async send({ to, from, subject, html, text, idempotencyKey }) {
    let res;
    try {
      res = await this.fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.apiKey}`, 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey.slice(0, 256) },
        body: JSON.stringify({ from, to: [to], subject, html, text }),
        signal: AbortSignal.timeout(10000),
      });
    } catch { throw new ProviderError('provider unreachable', { retryable: true }); }
    if (res.ok) { const j = await res.json().catch(() => ({})); return { id: j.id ?? null }; }
    // Never forward provider error bodies to clients; they may reveal configuration.
    throw new ProviderError(`provider rejected (${res.status})`, { retryable: res.status === 429 || res.status >= 500 });
  }
}

export class ConsoleProvider {
  name = 'console';
  constructor(log = console.log) { this.log = log; this.sent = []; }
  async send(m) { this.sent.push(m); this.log(`[console-provider] to=${m.to} subject=${m.subject}`); return { id: 'console-' + this.sent.length }; }
}

/** "Name <a@b.c>" -> {name, email}; Brevo wants them separately. */
export function parseFrom(from) {
  const m = /^(.*)<\s*([^<>\s]+@[^<>\s]+)\s*>$/.exec(from);
  if (!m) return { email: from.trim() };
  const name = m[1].trim().replace(/^["']|["']$/g, '');
  return name ? { name, email: m[2].trim() } : { email: m[2].trim() };
}

// Operator-only override so integration tests can point at a local fake; production leaves it unset.
const BREVO_BASE = process.env.BREVO_API_BASE || 'https://api.brevo.com';

/** Brevo transactional email (HTTP API). Works with a single verified sender address; no owned domain needed. */
export class BrevoProvider {
  name = 'brevo';
  constructor({ apiKey, fetchImpl }) { this.apiKey = apiKey; this.fetch = fetchImpl ?? fetch; }
  /** Checks the key without sending mail (GET /v3/account). Throws ProviderError if rejected/unreachable. */
  async verify() {
    let res;
    try {
      res = await this.fetch(`${BREVO_BASE}/v3/account`, { headers: { accept: 'application/json', 'api-key': this.apiKey }, signal: AbortSignal.timeout(10000) });
    } catch { throw new ProviderError('provider unreachable', { retryable: true }); }
    if (!res.ok) throw new ProviderError(`provider rejected (${res.status})`, { retryable: res.status === 429 || res.status >= 500 });
    return true;
  }
  async send({ to, from, subject, html, text }) {
    let res;
    try {
      res = await this.fetch(`${BREVO_BASE}/v3/smtp/email`, {
        method: 'POST',
        headers: { accept: 'application/json', 'content-type': 'application/json', 'api-key': this.apiKey },
        body: JSON.stringify({ sender: parseFrom(from), to: [{ email: to }], subject, htmlContent: html, textContent: text }),
        signal: AbortSignal.timeout(10000),
      });
    } catch { throw new ProviderError('provider unreachable', { retryable: true }); }
    if (res.ok) { const j = await res.json().catch(() => ({})); return { id: j.messageId ?? null }; }
    throw new ProviderError(`provider rejected (${res.status})`, { retryable: res.status === 429 || res.status >= 500 });
  }
}

export function createProvider(config, { fetchImpl } = {}) {
  switch (config.emailProvider) {
    case 'console': return new ConsoleProvider();
    case 'brevo':
      if (!config.brevoApiKey) throw new Error('BREVO_API_KEY required for provider "brevo"');
      return new BrevoProvider({ apiKey: config.brevoApiKey, fetchImpl });
    case 'resend':
      if (!config.resendApiKey) throw new Error('RESEND_API_KEY required for provider "resend"');
      return new ResendProvider({ apiKey: config.resendApiKey, fetchImpl });
    default: throw new Error(`Unknown EMAIL_PROVIDER "${config.emailProvider}" (use brevo, resend or console)`);
  }
}

export const maskEmail = (e) => e.replace(/^(.).*(@.*)$/, (_, a, d) => `${a}***${d}`);
