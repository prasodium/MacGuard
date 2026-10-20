const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const POWER = new Set(['connected', 'disconnected', 'unknown']);
const FRESH = new Set(['fresh', 'cached', 'lastKnown']);
const STATUS_CODES = new Set(['charger_reconnected', 'alarm_silenced', 'protection_disarmed']);
const ACTION = new Set(['notStarted', 'inProgress', 'succeeded', 'failed', 'skipped', 'requestedUnverified']);

export class ValidationError extends Error {}
const fail = (m) => { throw new ValidationError(m); };
const str = (v, name, max) => { if (typeof v !== 'string' || v.length === 0 || v.length > max) fail(`${name} invalid`); return v; };
const optStr = (v, name, max) => (v == null ? null : str(v, name, max));
const num = (v, name, lo, hi) => { if (typeof v !== 'number' || !Number.isFinite(v) || v < lo || v > hi) fail(`${name} out of range`); return v; };
const date = (v, name) => { const t = Date.parse(v); if (typeof v !== 'string' || Number.isNaN(t)) fail(`${name} invalid`); return new Date(t).toISOString(); };
const oneOf = (v, set, name) => { if (!set.has(v)) fail(`${name} invalid`); return v; };

export const isIncidentId = (v) => typeof v === 'string' && UUID.test(v);

export function validateLocation(l) {
  if (l == null) return null;
  return {
    latitude: num(l.latitude, 'latitude', -90, 90),
    longitude: num(l.longitude, 'longitude', -180, 180),
    accuracy: l.accuracy == null ? null : num(l.accuracy, 'accuracy', 0, 1e7),
    acquiredAt: date(l.acquiredAt, 'acquiredAt'),
    source: str(l.source ?? 'CoreLocation', 'source', 32),
    freshness: oneOf(l.freshness, FRESH, 'freshness'),
  };
}

export function validateIncident(b) {
  if (!b || typeof b !== 'object') fail('body');
  if (!isIncidentId(b.incidentId)) fail('incidentId invalid');
  const d = b.device || {};
  return {
    incidentId: b.incidentId,
    eventType: oneOf(b.eventType, new Set(['charger_disconnected', 'test']), 'eventType'),
    occurredAt: date(b.occurredAt, 'occurredAt'),
    timeZone: str(b.timeZone, 'timeZone', 64),
    device: { name: str(d.name, 'device.name', 64), model: optStr(d.model, 'device.model', 64), osVersion: str(d.osVersion, 'device.osVersion', 32) },
    powerBefore: oneOf(b.powerBefore, POWER, 'powerBefore'),
    powerAfter: oneOf(b.powerAfter, POWER, 'powerAfter'),
    batteryPercent: b.batteryPercent == null ? null : num(b.batteryPercent, 'batteryPercent', 0, 100),
    alarmStatus: oneOf(b.alarmStatus, ACTION, 'alarmStatus'),
    screenLockStatus: oneOf(b.screenLockStatus, ACTION, 'screenLockStatus'),
    locationStatus: str(b.locationStatus, 'locationStatus', 32),
    location: validateLocation(b.location),
    isTest: b.isTest === true,
  };
}

export function validateLocationUpdate(b, incidentId) {
  if (!b || typeof b !== 'object') fail('body');
  if (b.incidentId !== incidentId) fail('incidentId mismatch');
  return {
    incidentId,
    sequence: num(b.sequence, 'sequence', 1, 10000),
    location: validateLocation(b.location),
    locationStatus: str(b.locationStatus, 'locationStatus', 32),
    monitoringState: str(b.monitoringState, 'monitoringState', 32),
    isFollowUp: b.isFollowUp === true,
    sentAt: date(b.sentAt, 'sentAt'),
  };
}

export function validateStatus(b, incidentId) {
  if (!b || typeof b !== 'object') fail('body');
  if (b.incidentId !== incidentId) fail('incidentId mismatch');
  return {
    incidentId,
    statusCode: oneOf(b.statusCode, STATUS_CODES, 'statusCode'),
    monitoringState: str(b.monitoringState, 'monitoringState', 32),
    timestamp: date(b.timestamp, 'timestamp'),
  };
}

export function validateEnroll(b) {
  if (!b || typeof b !== 'object') fail('body');
  const secret = str(b.secret, 'secret', 128);
  if (Buffer.from(secret, 'base64').length < 32) fail('secret too short');
  return {
    enrollmentToken: str(b.enrollmentToken, 'enrollmentToken', 128),
    installationId: str(b.installationId, 'installationId', 64),
    secret, deviceName: optStr(b.deviceName, 'deviceName', 64) ?? 'Mac',
  };
}

const EMAIL = /^[^\s@<>"',;]{1,64}@[^\s@<>"',;]{1,190}\.[^\s@<>"',;]{2,24}$/;
const email = (v, name) => { if (typeof v !== 'string' || v.length > 254 || !EMAIL.test(v)) fail(`${name} invalid`); return v.trim().toLowerCase(); };

export function validateProviderConfig(b) {
  if (!b || typeof b !== 'object') fail('body');
  const apiKey = str(b.apiKey, 'apiKey', 200);
  if (apiKey.length < 10 || /\s/.test(apiKey)) fail('apiKey invalid');
  return { provider: oneOf(b.provider, new Set(['brevo', 'resend']), 'provider'), apiKey, fromEmail: email(b.fromEmail, 'fromEmail') };
}
export function validateRecipientRequest(b) { if (!b || typeof b !== 'object') fail('body'); return { email: email(b.email, 'email') }; }
export function validateRecipientConfirm(b) {
  if (!b || typeof b !== 'object') fail('body');
  const code = str(b.code, 'code', 6); if (!/^\d{6}$/.test(code)) fail('code invalid');
  return { email: email(b.email, 'email'), code };
}
