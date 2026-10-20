import Testing
import Foundation
@testable import MacGuardCore

@Suite struct EmailTemplateTests {
    func payload(location: LocationPayload? = nil, device: DeviceInfo = dev) -> IncidentPayload {
        IncidentPayload(incidentId: "0b6f3a52-7a31-4c1a-9f0e-5d0c2f0a8b11", eventType: "charger_disconnected", occurredAt: Date(timeIntervalSince1970: 1_760_000_000),
                        timeZone: "Asia/Kolkata", device: device, powerBefore: "connected", powerAfter: "disconnected", batteryPercent: 80,
                        alarmStatus: "succeeded", screenLockStatus: "requestedUnverified", locationStatus: location == nil ? "timedOut" : "acquired",
                        location: location, isTest: false)
    }
    func loc(_ fresh: String, lat: Double = 12.9716, lon: Double = 77.5946) -> LocationPayload {
        LocationPayload(LocationRecord(latitude: lat, longitude: lon, horizontalAccuracy: 12, acquiredAt: Date(timeIntervalSince1970: 1_760_000_000),
                                       freshness: fresh == "fresh" ? .fresh : fresh == "cached" ? .cached : .lastKnown)!)
    }

    @Test func mapLinkOnlyForValidCoordinates() {
        #expect(EmailTemplates.mapURL(latitude: 100, longitude: 0) == nil)
        #expect(EmailTemplates.mapURL(latitude: 0, longitude: 181) == nil)
        #expect(EmailTemplates.mapURL(latitude: .nan, longitude: 0) == nil)
        #expect(EmailTemplates.mapURL(latitude: 1, longitude: 2)?.hasPrefix("https://maps.apple.com/?ll=1.000000,2.000000") == true)
    }
    @Test func missingLocationIsDisclosedWithNoMapLink() {
        let r = EmailTemplates.incident(payload())
        #expect(r.html.contains("LOCATION UNAVAILABLE")); #expect(r.text.contains("LOCATION UNAVAILABLE"))
        #expect(!r.html.contains("maps.apple.com")); #expect(!r.text.contains("maps.apple.com"))
    }
    @Test func freshnessLabelsAreHonest() {
        #expect(EmailTemplates.incident(payload(location: loc("fresh"))).text.contains("FRESH LOCATION"))
        let c = EmailTemplates.incident(payload(location: loc("cached")))
        #expect(c.text.contains("CACHED LOCATION")); #expect(c.text.contains("NOT live"))
        let k = EmailTemplates.incident(payload(location: loc("lastKnown")))
        #expect(k.text.contains("LAST KNOWN LOCATION")); #expect(k.html.contains("LAST KNOWN LOCATION")); #expect(k.text.contains("NOT live"))
        #expect(k.html.contains("estimate")); #expect(k.html.contains("Open in Apple Maps"))
    }
    @Test func requiredFieldsArePresent() {
        let r = EmailTemplates.incident(payload(location: loc("fresh")))
        for needle in ["0b6f3a52-7a31-4c1a-9f0e-5d0c2f0a8b11", "Name: Test", "Model: Mac14,2", "macOS: 27.0", "connected → disconnected", "Asia/Kolkata",
                       "Battery: 80%", "Alarm: succeeded", "Screen-lock request: requestedUnverified", "±12 m", "12.971600, 77.594600", "RECOVERY", "Find My"] {
            #expect(r.text.contains(needle), "missing \(needle)")
        }
        #expect(r.subject == "MACGUARD ALERT: Unauthorized Charger Disconnection")
    }
    @Test func htmlIsEscaped() {
        let r = EmailTemplates.incident(payload(device: DeviceInfo(name: "<script>alert(1)</script>", model: nil, osVersion: "27")))
        #expect(!r.html.contains("<script>alert")); #expect(r.html.contains("&lt;script&gt;"))
    }
    @Test func followUpAndStatusEmails() {
        let u = LocationUpdatePayload(incidentId: "i", sequence: 2, location: loc("fresh"), locationStatus: "acquired", monitoringState: "healthy", isFollowUp: true, sentAt: Date())
        let f = EmailTemplates.location(u)
        #expect(f.subject == "MACGUARD FOLLOW-UP: Location update (#2)"); #expect(f.text.contains("not continuous real-time tracking"))
        let s = EmailTemplates.status(StatusPayload(incidentId: "i", statusCode: "charger_reconnected", monitoringState: "healthy", timestamp: Date()))
        #expect(s.text.contains("does NOT mean the Mac is back")); #expect(!s.text.contains("maps.apple.com"))
    }
    @Test func verificationAndMasking() {
        let v = EmailTemplates.verification(code: "123456")
        #expect(v.text.contains("code is 123456")); #expect(v.html.contains("123456"))
        #expect(EmailTemplates.mask("owner@example.com") == "o***@example.com")
        #expect(EmailTemplates.recipientChanged(newAddress: "new@gmail.com").text.contains("n***@gmail.com"))
    }
}
