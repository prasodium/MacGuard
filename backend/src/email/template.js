const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export function mapUrl(loc) {
  if (!loc || !Number.isFinite(loc.latitude) || !Number.isFinite(loc.longitude)) return null;
  if (Math.abs(loc.latitude) > 90 || Math.abs(loc.longitude) > 180) return null;
  return `https://maps.apple.com/?ll=${loc.latitude.toFixed(6)},${loc.longitude.toFixed(6)}&q=${encodeURIComponent('MacGuard reported position')}`;
}

function locationLines(loc, status) {
  if (!loc) return { label: 'LOCATION UNAVAILABLE', lines: [`No location was available (${status}). No coordinates are included.`], url: null };
  const label = loc.freshness === 'lastKnown' ? 'LAST KNOWN LOCATION' : loc.freshness === 'cached' ? 'CACHED LOCATION' : 'FRESH LOCATION';
  const lines = [
    `Latitude / Longitude: ${loc.latitude.toFixed(6)}, ${loc.longitude.toFixed(6)}`,
    `Estimated accuracy: ${loc.accuracy == null ? 'unknown' : '±' + Math.round(loc.accuracy) + ' m'}`,
    `Location fix time: ${loc.acquiredAt}`,
    `Freshness: ${loc.freshness}`,
  ];
  if (loc.freshness !== 'fresh') lines.push('This position is NOT live; the Mac may have moved since this fix.');
  return { label, lines, url: mapUrl(loc) };
}

const RECOVERY = [
  'Open Find My (icloud.com/find) on another device and select this Mac.',
  'Use Lost Mode if appropriate. Availability depends on Apple\'s service and the Mac\'s state.',
  'If theft is suspected, contact local authorities. Do not confront anyone.',
];

function render({ heading, summary, device, loc, locStatus, extra = [], timeline = [], preheader }) {
  const L = locationLines(loc, locStatus);
  const text = [heading, '', ...summary, '', 'DEVICE', ...device, '', L.label, ...L.lines,
    ...(L.url ? [`Map (estimate, not proof of exact position): ${L.url}`] : []), ...extra,
    ...(timeline.length ? ['', 'TIMELINE', ...timeline] : []), '', 'RECOVERY', ...RECOVERY.map((r) => '- ' + r),
    '', 'MacGuard is a deterrent and recovery aid; delivery of this email is not guaranteed.'].join('\n');
  const li = (a) => a.map((x) => `<li style="margin:2px 0">${esc(x)}</li>`).join('');
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"></head>
<body style="margin:0;background:#f4f4f5;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#18181b">
<span style="display:none">${esc(preheader || heading)}</span>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:16px">
<table role="presentation" width="100%" style="max-width:600px;background:#fff;border-radius:10px;overflow:hidden;border:1px solid #e4e4e7">
<tr><td style="background:#b91c1c;color:#fff;padding:16px 20px;font-size:20px;font-weight:700">${esc(heading)}</td></tr>
<tr><td style="padding:16px 20px"><ul style="padding-left:18px;margin:0">${li(summary)}</ul></td></tr>
<tr><td style="padding:0 20px 8px"><div style="font-weight:700;margin-bottom:4px">Device</div><ul style="padding-left:18px;margin:0">${li(device)}</ul></td></tr>
<tr><td style="padding:12px 20px"><div style="border:1px solid #e4e4e7;border-radius:8px;padding:12px">
<div style="font-weight:700;color:${loc ? '#18181b' : '#b45309'}">${esc(L.label)}</div><ul style="padding-left:18px;margin:6px 0">${li(L.lines)}</ul>
${L.url ? `<a href="${esc(L.url)}" style="display:inline-block;background:#1d4ed8;color:#fff;text-decoration:none;padding:10px 16px;border-radius:6px;font-weight:600">Open in Apple Maps</a>
<div style="font-size:12px;color:#52525b;margin-top:6px">The pin is an estimate from reported coordinates, not proof of the exact physical location.</div>` : ''}
</div></td></tr>
${extra.length ? `<tr><td style="padding:0 20px"><ul style="padding-left:18px">${li(extra)}</ul></td></tr>` : ''}
${timeline.length ? `<tr><td style="padding:8px 20px"><div style="font-weight:700">Timeline</div><ul style="padding-left:18px;margin:4px 0">${li(timeline)}</ul></td></tr>` : ''}
<tr><td style="padding:8px 20px 16px"><div style="font-weight:700">Recovery</div><ul style="padding-left:18px;margin:4px 0">${li(RECOVERY)}</ul></td></tr>
<tr><td style="padding:12px 20px;background:#fafafa;font-size:12px;color:#52525b">MacGuard is a deterrent and recovery aid. Email delivery is not guaranteed.</td></tr>
</table></td></tr></table></body></html>`;
  return { html, text };
}

const deviceLines = (d) => [`Name: ${d.name}`, ...(d.model ? [`Model: ${d.model}`] : []), `macOS: ${d.osVersion}`];

export function incidentEmail(p, { notificationStatus = 'accepted by backend' } = {}) {
  const test = p.eventType === 'test';
  const heading = test ? 'MACGUARD TEST: Your alert email works' : 'MACGUARD ALERT: Unauthorized Charger Disconnection';
  const summary = [
    `Incident: ${p.incidentId}`, `Event: ${test ? 'Test message (no incident)' : 'Charger disconnected while protection was armed'}`,
    `Charger before → after: ${p.powerBefore} → ${p.powerAfter}`, `Time: ${p.occurredAt} (${p.timeZone})`,
    `Battery: ${p.batteryPercent == null ? 'unknown' : p.batteryPercent + '%'}`,
    `Alarm: ${p.alarmStatus}`, `Screen-lock request: ${p.screenLockStatus}`,
    `Location status: ${p.locationStatus}`, `Notification: ${notificationStatus}`,
  ];
  const timeline = test ? [] : [`${p.occurredAt} — charger disconnection confirmed`, `Alarm: ${p.alarmStatus}`, `Screen lock: ${p.screenLockStatus}`];
  return { subject: test ? 'MACGUARD TEST: Alert email' : 'MACGUARD ALERT: Unauthorized Charger Disconnection',
    ...render({ heading, summary, device: deviceLines(p.device), loc: p.location, locStatus: p.locationStatus, timeline,
      preheader: 'Charger disconnected while protection was armed' }) };
}

export function locationEmail(p) {
  const heading = p.isFollowUp ? 'MACGUARD FOLLOW-UP: Location update' : 'MACGUARD ALERT: Location update';
  const summary = [`Original incident: ${p.incidentId}`, `Update #${p.sequence}${p.isFollowUp ? ' (follow-up)' : ''}`,
    `Sent: ${p.sentAt}`, `Monitoring status: ${p.monitoringState}`, `Location status: ${p.locationStatus}`];
  return { subject: `${heading} (#${p.sequence})`,
    ...render({ heading, summary, device: ['See original alert for device details'], loc: p.location, locStatus: p.locationStatus,
      extra: ['MacGuard obtains occasional location fixes; this is not continuous real-time tracking.'] }) };
}

const STATUS_TEXT = {
  charger_reconnected: 'The charger was reconnected. This does NOT mean the Mac is back with its owner or unlocked.',
  alarm_silenced: 'The alarm was silenced after owner authentication.',
  protection_disarmed: 'Protection was disarmed after owner authentication.',
};
export function statusEmail(p) {
  const heading = 'MACGUARD STATUS: ' + p.statusCode.replaceAll('_', ' ');
  const summary = [`Original incident: ${p.incidentId}`, STATUS_TEXT[p.statusCode], `Time: ${p.timestamp}`, `Monitoring status: ${p.monitoringState}`];
  return { subject: heading, ...render({ heading, summary, device: ['See original alert for device details'], loc: null, locStatus: 'not included in status updates' }) };
}
