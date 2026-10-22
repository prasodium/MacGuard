import Foundation

/// Builds the alert emails (responsive HTML + plain-text alternative). Pure functions, no I/O.
public enum EmailTemplates {
    public struct Rendered: Equatable, Sendable { public var subject: String, html: String, text: String }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// Apple Maps link built only from validated numeric coordinates.
    public static func mapURL(latitude: Double, longitude: Double) -> String? {
        guard LocationRecord.isValid(latitude: latitude, longitude: longitude) else { return nil }
        return String(format: "https://maps.apple.com/?ll=%.6f,%.6f&q=MacGuard%%20reported%%20position", latitude, longitude)
    }

    private static let recovery = [
        "Open Find My (icloud.com/find) on another device and select this Mac.",
        "Use Lost Mode if appropriate. Availability depends on Apple's service and the Mac's state.",
        "If theft is suspected, contact local authorities. Do not confront anyone.",
    ]

    private static func locationBlock(_ loc: LocationPayload?, status: String) -> (label: String, lines: [String], url: String?) {
        guard let loc else { return ("LOCATION UNAVAILABLE", ["No location was available (\(status)). No coordinates are included."], nil) }
        let label = loc.freshness == "lastKnown" ? "LAST KNOWN LOCATION" : loc.freshness == "cached" ? "CACHED LOCATION" : "FRESH LOCATION"
        var lines = [
            String(format: "Latitude / Longitude: %.6f, %.6f", loc.latitude, loc.longitude),
            "Estimated accuracy: " + (loc.accuracy.map { "±\(Int($0.rounded())) m" } ?? "unknown"),
            "Location fix time: \(iso(loc.acquiredAt))",
            "Freshness: \(loc.freshness)",
        ]
        if loc.freshness != "fresh" { lines.append("This position is NOT live; the Mac may have moved since this fix.") }
        return (label, lines, mapURL(latitude: loc.latitude, longitude: loc.longitude))
    }

    private static func render(heading: String, summary: [String], device: [String], loc: LocationPayload?, locStatus: String,
                               extra: [String] = [], timeline: [String] = [], preheader: String? = nil) -> (html: String, text: String) {
        let L = locationBlock(loc, status: locStatus)
        var t: [String] = [heading, ""] + summary + ["", "DEVICE"] + device + ["", L.label] + L.lines
        if let u = L.url { t.append("Map (estimate, not proof of exact position): \(u)") }
        t += extra
        if !timeline.isEmpty { t += ["", "TIMELINE"] + timeline }
        t += ["", "RECOVERY"] + recovery.map { "- " + $0 }
        t += ["", "MacGuard is a deterrent and recovery aid; delivery of this email is not guaranteed."]

        func li(_ a: [String]) -> String { a.map { "<li style=\"margin:2px 0\">\(esc($0))</li>" }.joined() }
        let mapButton = L.url.map { u in """
            <a href="\(esc(u))" style="display:inline-block;background:#1d4ed8;color:#fff;text-decoration:none;padding:10px 16px;border-radius:6px;font-weight:600">Open in Apple Maps</a>
            <div style="font-size:12px;color:#52525b;margin-top:6px">The pin is an estimate from reported coordinates, not proof of the exact physical location.</div>
            """ } ?? ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"></head>
        <body style="margin:0;background:#f4f4f5;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#18181b">
        <span style="display:none">\(esc(preheader ?? heading))</span>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:16px">
        <table role="presentation" width="100%" style="max-width:600px;background:#fff;border-radius:10px;overflow:hidden;border:1px solid #e4e4e7">
        <tr><td style="background:#b91c1c;color:#fff;padding:16px 20px;font-size:20px;font-weight:700">\(esc(heading))</td></tr>
        <tr><td style="padding:16px 20px"><ul style="padding-left:18px;margin:0">\(li(summary))</ul></td></tr>
        <tr><td style="padding:0 20px 8px"><div style="font-weight:700;margin-bottom:4px">Device</div><ul style="padding-left:18px;margin:0">\(li(device))</ul></td></tr>
        <tr><td style="padding:12px 20px"><div style="border:1px solid #e4e4e7;border-radius:8px;padding:12px">
        <div style="font-weight:700;color:\(loc == nil ? "#b45309" : "#18181b")">\(esc(L.label))</div><ul style="padding-left:18px;margin:6px 0">\(li(L.lines))</ul>
        \(mapButton)
        </div></td></tr>
        \(extra.isEmpty ? "" : "<tr><td style=\"padding:0 20px\"><ul style=\"padding-left:18px\">\(li(extra))</ul></td></tr>")
        \(timeline.isEmpty ? "" : "<tr><td style=\"padding:8px 20px\"><div style=\"font-weight:700\">Timeline</div><ul style=\"padding-left:18px;margin:4px 0\">\(li(timeline))</ul></td></tr>")
        <tr><td style="padding:8px 20px 16px"><div style="font-weight:700">Recovery</div><ul style="padding-left:18px;margin:4px 0">\(li(recovery))</ul></td></tr>
        <tr><td style="padding:12px 20px;background:#fafafa;font-size:12px;color:#52525b">MacGuard is a deterrent and recovery aid. Email delivery is not guaranteed.</td></tr>
        </table></td></tr></table></body></html>
        """
        return (html, t.joined(separator: "\n"))
    }

    private static func deviceLines(_ d: DeviceInfo) -> [String] {
        ["Name: \(d.name)"] + (d.model.map { ["Model: \($0)"] } ?? []) + ["macOS: \(d.osVersion)"]
    }

    public static func incident(_ p: IncidentPayload) -> Rendered {
        let test = p.eventType == "test"
        let heading = test ? "MACGUARD TEST: Your alert email works" : "MACGUARD ALERT: Unauthorized Charger Disconnection"
        let summary = [
            "Incident: \(p.incidentId)",
            "Event: " + (test ? "Test message (no incident)" : "Charger disconnected while protection was armed"),
            "Charger before → after: \(p.powerBefore) → \(p.powerAfter)",
            "Time: \(iso(p.occurredAt)) (\(p.timeZone))",
            "Battery: " + (p.batteryPercent.map { "\($0)%" } ?? "unknown"),
            "Alarm: \(p.alarmStatus)", "Screen-lock request: \(p.screenLockStatus)",
            "Location status: \(p.locationStatus)",
        ]
        let timeline = test ? [] : ["\(iso(p.occurredAt)) — charger disconnection confirmed", "Alarm: \(p.alarmStatus)", "Screen lock: \(p.screenLockStatus)"]
        let r = render(heading: heading, summary: summary, device: deviceLines(p.device), loc: p.location, locStatus: p.locationStatus,
                       timeline: timeline, preheader: "Charger disconnected while protection was armed")
        return Rendered(subject: test ? "MACGUARD TEST: Alert email" : heading, html: r.html, text: r.text)
    }

    public static func location(_ p: LocationUpdatePayload) -> Rendered {
        let heading = p.isFollowUp ? "MACGUARD FOLLOW-UP: Location update" : "MACGUARD ALERT: Location update"
        let summary = ["Original incident: \(p.incidentId)", "Update #\(p.sequence)" + (p.isFollowUp ? " (follow-up)" : ""),
                       "Sent: \(iso(p.sentAt))", "Monitoring status: \(p.monitoringState)", "Location status: \(p.locationStatus)"]
        let r = render(heading: heading, summary: summary, device: ["See original alert for device details"], loc: p.location, locStatus: p.locationStatus,
                       extra: ["MacGuard obtains occasional location fixes; this is not continuous real-time tracking."])
        return Rendered(subject: "\(heading) (#\(p.sequence))", html: r.html, text: r.text)
    }

    public static func status(_ p: StatusPayload) -> Rendered {
        let texts = [
            "charger_reconnected": "The charger was reconnected. This does NOT mean the Mac is back with its owner or unlocked.",
            "alarm_silenced": "The alarm was silenced after owner authentication.",
            "protection_disarmed": "Protection was disarmed after owner authentication.",
            "mac_found": "The owner confirmed the Mac was found. No more location emails will be sent for this incident.",
        ]
        let heading = "MACGUARD STATUS: " + p.statusCode.replacingOccurrences(of: "_", with: " ")
        let summary = ["Original incident: \(p.incidentId)", texts[p.statusCode] ?? p.statusCode, "Time: \(iso(p.timestamp))", "Monitoring status: \(p.monitoringState)"]
        let r = render(heading: heading, summary: summary, device: ["See original alert for device details"], loc: nil, locStatus: "not included in status updates")
        return Rendered(subject: heading, html: r.html, text: r.text)
    }

    public static func verification(code: String) -> Rendered {
        Rendered(subject: "MacGuard: your verification code",
                 html: "<p>Your MacGuard verification code is <b style=\"font-size:20px;letter-spacing:2px\">\(esc(code))</b>.</p><p>It expires in 15 minutes. If you did not request this, ignore this email.</p>",
                 text: "Your MacGuard verification code is \(code). It expires in 15 minutes.\nIf you did not request this, ignore this email.")
    }

    public static func recipientChanged(newAddress: String) -> Rendered {
        Rendered(subject: "MacGuard: alert recipient changed",
                 html: "<p>MacGuard alert emails now go to <b>\(esc(mask(newAddress)))</b>.</p><p>If this was not you, remove the Brevo key in MacGuard and create a new one.</p>",
                 text: "MacGuard alert emails now go to \(mask(newAddress)).\nIf this was not you, remove the Brevo key in MacGuard and create a new one.")
    }

    public static func mask(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), let first = email.first else { return email }
        return "\(first)***\(email[at...])"
    }
}
