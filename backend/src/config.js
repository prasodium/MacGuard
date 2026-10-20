// All configuration comes from environment variables; nothing is hard-coded.
export function loadConfig(env = process.env) {
  const need = (k) => { if (!env[k]) throw new Error(`Missing required env var ${k}`); return env[k]; };
  return {
    port: Number(env.PORT || 8787),
    ownerEmail: need('OWNER_EMAIL'),        // the ONLY recipient; clients cannot choose recipients
    fromEmail: need('FROM_EMAIL'),          // e.g. "MacGuard <alerts@yourdomain.com>"
    resendApiKey: env.RESEND_API_KEY || '', // empty only allowed with EMAIL_PROVIDER=console
    emailProvider: env.EMAIL_PROVIDER || 'resend',
    dataDir: env.DATA_DIR || './data',
    maxBodyBytes: Number(env.MAX_BODY_BYTES || 16 * 1024),
    clockSkewSeconds: Number(env.CLOCK_SKEW_SECONDS || 300),
    rateLimitPerMinute: Number(env.RATE_LIMIT_PER_MINUTE || 20),
    enrollRateLimitPerHour: Number(env.ENROLL_RATE_LIMIT_PER_HOUR || 10),
  };
}
