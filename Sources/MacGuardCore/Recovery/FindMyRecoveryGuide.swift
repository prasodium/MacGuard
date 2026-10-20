import Foundation

public enum FindMyRecoveryGuide {
    public static let findMyURL = URL(string: "https://www.icloud.com/find")!
    public static let steps: [(title: String, body: String)] = [
        ("Make sure Find My Mac is on", "System Settings → [your name] → iCloud → Find My Mac → On. Also enable \"Find My network\" so the Mac can be located while offline."),
        ("Check the right Apple Account", "Confirm the Apple Account signed in on this Mac is the one you can access from another device."),
        ("Review the reported location", "Open Find My on another device or at icloud.com/find and select this Mac. The location shown depends on Apple's service and the Mac's connectivity; it may be old or unavailable."),
        ("Mark as Lost if needed", "Lost Mode locks the Mac with a passcode and can show a message. Availability depends on Apple's service and the Mac's configuration."),
        ("If theft is suspected", "Contact local authorities and give them the serial number (Apple menu → About This Mac). Do not confront anyone."),
    ]
    public static let disclaimer = "MacGuard cannot read live coordinates from Find My. It never asks for your Apple Account password and never automates Apple sign-in."
}
