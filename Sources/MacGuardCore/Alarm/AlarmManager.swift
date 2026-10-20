import Foundation
import AppKit

public protocol SoundPlaying: AnyObject {
    @MainActor func play(named: String) -> Bool
    @MainActor func stopAll()
}

@MainActor
public final class SystemSoundPlayer: SoundPlaying {
    private var current: NSSound?
    public init() {}
    public static let availableSounds = ["Sosumi", "Basso", "Glass", "Funk", "Hero", "Submarine", "Ping", "Blow"]
    public func play(named: String) -> Bool {
        current?.stop()
        guard let s = NSSound(named: NSSound.Name(named)) else { return false }
        current = s
        return s.play()
    }
    public func stopAll() { current?.stop(); current = nil }
}

public protocol AlarmControlling: AnyObject {
    @MainActor var isActive: Bool { get }
    @MainActor func start(settings: AlarmSettings) -> Bool
    @MainActor func stop()
    @MainActor func preview(settings: AlarmSettings)
}

/// Repeating alarm. Starts promptly, repeats until stopped (stop is gated by owner auth in the UI layer).
@MainActor
public final class AlarmManager: AlarmControlling, ObservableObject {
    @Published public private(set) var isActive = false
    private let player: SoundPlaying
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    public var onChange: ((Bool) -> Void)?

    public init(player: SoundPlaying) { self.player = player }

    @discardableResult
    public func start(settings: AlarmSettings) -> Bool {
        guard !isActive else { return true }
        if settings.maximizeVolume { Self.setSystemVolumeMax() }
        isActive = true; onChange?(true)
        let firstOK = settings.initialDelay <= 0 ? player.play(named: settings.sound) : true
        task = Task { [weak self] in
            if settings.initialDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(settings.initialDelay * 1e9))
                guard !Task.isCancelled else { return }
                _ = self?.player.play(named: settings.sound)
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, settings.repeatInterval) * 1e9))
                guard !Task.isCancelled else { return }
                _ = self?.player.play(named: settings.sound)
            }
        }
        return firstOK
    }

    public func stop() {
        task?.cancel(); task = nil
        player.stopAll()
        if isActive { isActive = false; onChange?(false) }
    }

    public func preview(settings: AlarmSettings) {
        previewTask?.cancel()
        _ = player.play(named: settings.sound)
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled, self?.isActive == false { self?.player.stopAll() }
        }
    }

    /// Unmutes and raises output volume (owner-configurable). Hardware routing still applies.
    nonisolated static func setSystemVolumeMax() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "set volume without output muted", "-e", "set volume output volume 100"]
        try? p.run()
    }
}
