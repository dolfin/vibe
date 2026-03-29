import Foundation
import Network

/// Returns true as soon as host:port accepts a TCP connection (500ms timeout per attempt).
func tcpPortOpen(host: String, port: UInt16) async -> Bool {
    await withCheckedContinuation { continuation in
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            continuation.resume(returning: false)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let q = DispatchQueue(label: "app.dotvibe.Vibe.tcpProbe.\(port)")
        var done = false

        @Sendable func finish(_ result: Bool) {
            q.async {
                guard !done else { return }
                done = true
                connection.cancel()
                continuation.resume(returning: result)
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:              finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        connection.start(queue: q)
        q.asyncAfter(deadline: .now() + 0.5) { finish(false) }
    }
}
