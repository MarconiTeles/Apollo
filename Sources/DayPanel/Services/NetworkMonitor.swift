import Foundation
import Network
import Combine

final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "com.daypanel.network")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
