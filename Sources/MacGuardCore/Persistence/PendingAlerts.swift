import Foundation
import Network

/// Triggers a callback when the network becomes reachable again.
public final class ConnectivityWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var wasSatisfied = true
    public private(set) var isOnline = true
    public init() {}
    public func start(onReconnect: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let ok = path.status == .satisfied
            if ok && !self.wasSatisfied { onReconnect() }
            self.wasSatisfied = ok; self.isOnline = ok
        }
        monitor.start(queue: DispatchQueue(label: "macguard.net"))
    }
    public func stop() { monitor.cancel() }
}
