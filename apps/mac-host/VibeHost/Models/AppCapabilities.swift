import Foundation

/// Capabilities extracted from a Vibe app manifest.
struct AppCapabilities: Codable, Equatable {
    var network: Bool
    var allowHostFileImport: Bool
    var exposedPorts: [UInt16]
    var requiredSecrets: [String]

    init(from manifest: AppManifest) {
        self.network = manifest.security?.network ?? false
        self.allowHostFileImport = manifest.security?.allowHostFileImport ?? false

        var ports: [UInt16] = []
        for service in manifest.services ?? [] {
            for port in service.ports ?? [] {
                ports.append(port.container)
            }
        }
        self.exposedPorts = ports

        self.requiredSecrets = (manifest.secrets ?? [])
            .filter { $0.required ?? false }
            .map(\.name)
    }

    init(network: Bool = false, allowHostFileImport: Bool = false, exposedPorts: [UInt16] = [], requiredSecrets: [String] = []) {
        self.network = network
        self.allowHostFileImport = allowHostFileImport
        self.exposedPorts = exposedPorts
        self.requiredSecrets = requiredSecrets
    }
}
