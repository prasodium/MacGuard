/** Fixed-window in-memory limiter keyed by string. */
export class RateLimiter {
  constructor(limit, windowMs) { this.limit = limit; this.windowMs = windowMs; this.hits = new Map(); }
  allow(key, now = Date.now()) {
    const e = this.hits.get(key);
    if (!e || now - e.start >= this.windowMs) { this.hits.set(key, { start: now, n: 1 }); this.#gc(now); return this.limit >= 1; }
    e.n += 1; return e.n <= this.limit;
  }
  #gc(now) { if (this.hits.size > 5000) for (const [k, e] of this.hits) if (now - e.start >= this.windowMs) this.hits.delete(k); }
}
