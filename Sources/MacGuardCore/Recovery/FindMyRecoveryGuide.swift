import Foundation

public enum FindMyRecoveryGuide {
    public static let findMyURL = URL(string: "https://www.icloud.com/find")!
    public static let steps: [(title: String, body: String)] = [
        ("Turn on Find My Mac", "System Settings → your name → iCloud → Find My Mac."),
        ("Use the right Apple Account", "Sign in to the same account on another device."),
        ("Check the location", "Open icloud.com/find and select this Mac."),
        ("Mark as Lost", "Locks the Mac with a passcode."),
        ("If stolen", "Contact the police. Don't confront anyone."),
    ]
    public static let disclaimer = "MacGuard cannot read Find My locations and never asks for your Apple password."
}
