import Foundation
import Network

/// Fast, active reachability probe. Unlike NWPathMonitor (which only says a
/// network interface exists), this opens a real TCP connection to the host and
/// reports success only if it connects within `timeout`. Lets us skip a slow
/// cloud upload and go straight to local when the link is bad or absent.
enum Reachability {
    static func canReach(host: String, port: UInt16 = 443, timeout: TimeInterval = 1.2) async -> Bool {
        final class Once { var done = false; let lock = NSLock() }
        let once = Once()

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let queue = DispatchQueue(label: "groqvoice.reachability")

            @Sendable func finish(_ reachable: Bool) {
                once.lock.lock()
                let already = once.done
                once.done = true
                once.lock.unlock()
                guard !already else { return }
                conn.cancel()
                cont.resume(returning: reachable)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
