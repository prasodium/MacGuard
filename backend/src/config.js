// All configuration comes from environment variables; nothing is hard-coded.
export function loadConfig(env = process.env) {
  return {
    port: Number(env.PORT || 8787),
    // Optional bootstrap values. Both can instead be set from the app (Settings → Email); the recipient
    // set there only becomes active after the address is verified with an emailed code.
    ownerEmail: env.OWNER_EMAIL || '',
    fromEmail: env.FROM_EMAIL || '',
    emailProvider: env.EMAIL_PROVIDER || 'brevo', // brevo | resend | console
    brevoApiKey: env.BREVO_API_KEY || '',
    resendApiKey: env.RESEND_API_KEY || '',
    dataDir: env.DATA_DIR || './data',
    maxBodyBytes: Number(env.MAX_BODY_BYTES || 16 * 1024),
    clockSkewSeconds: Number(env.CLOCK_SKEW_SECONDS || 300),
    rateLimitPerMinute: Number(env.RATE_LIMIT_PER_MINUTE || 20),
    configRateLimitPerHour: Number(env.CONFIG_RATE_LIMIT_PER_HOUR || 20),
    enrollRateLimitPerHour: Number(env.ENROLL_RATE_LIMIT_PER_HOUR || 10),
  };
}
