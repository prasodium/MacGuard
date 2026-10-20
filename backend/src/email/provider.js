/** Provider abstraction: any provider implements send({to,from,subject,html,text,idempotencyKey}). */
export class ProviderError extends Error {
  constructor(message, { retryable }) { super(message); this.retryable = retryable; }
}

export class ResendProvider {
  constructor({ apiKey, fetchImpl = fetch }) { this.apiKey = apiKey; this.fetch = fetchImpl; }
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
  constructor(log = console.log) { this.log = log; this.sent = []; }
  async send(m) { this.sent.push(m); this.log(`[console-provider] to=${m.to} subject=${m.subject}`); return { id: 'console-' + this.sent.length }; }
}
