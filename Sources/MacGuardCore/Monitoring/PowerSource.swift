import Foundation
import IOKit.ps

public enum PowerReadError: Error, Equatable { case unavailable }

public protocol PowerSourceReading: Sendable {
    func read() throws -> PowerSnapshot
}

/// Reads the providing power source via IOKit's public IOPowerSources API.
public struct IOKitPowerReader: PowerSourceReading {
    public init() {}

    public func read() throws -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { throw PowerReadError.unavailable }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var external: ExternalPower = .unknown
        switch providing {
        case kIOPSACPowerValue: external = .connected
        case kIOPSBatteryPowerValue: external = .disconnected
        case "UPS Power": external = .disconnected
        default: external = .unknown
        }
        var percent: Int?, charging: Bool?, charged: Bool?
        var hasBattery = false
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
                guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                hasBattery = true
                if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percent = Int((Double(cur) / Double(max) * 100).rounded())
                }
                charging = d[kIOPSIsChargingKey] as? Bool
                charged = d[kIOPSIsChargedKey] as? Bool
            }
        }
        return PowerSnapshot(external: external, batteryPercent: percent, isCharging: charging,
                             isFullyCharged: charged, hasBattery: hasBattery)
    }
}

/// Event-driven change notifications (IOPSNotificationCreateRunLoopSource) on the main run loop.
public final class IOKitPowerNotifier: @unchecked Sendable {
    private var source: CFRunLoopSource?
    private var handler: (@Sendable () -> Void)?
    public init() {}

    public func start(_ handler: @escaping @Sendable () -> Void) {
        stop()
        self.handler = handler
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<IOKitPowerNotifier>.fromOpaque(ctx).takeUnretainedValue().handler?()
        }, ctx)?.takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    }

    public func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        source = nil; handler = nil
    }
    deinit { stop() }
}
