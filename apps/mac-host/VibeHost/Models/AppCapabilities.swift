import Foundation

/// Capabilities extracted from a Vibe app manifest.
struct AppCapabilities: Codable, Equatable {
    var network: Bool
    var allowHostFileImport: Bool
    var exposedPorts: [UInt16]
    var secrets: [SecretMeta]

    struct SecretMeta: Codable, Equatable {
        let name: String
        let required: Bool
        let howToObtain: String?
    }

    /// Names of secrets marked `required: true`.
    var requiredSecrets: [String] { secrets.filter(\.required).map(\.name) }
    /// Names of all declared secrets.
    var declaredSecrets: [String] { secrets.map(\.name) }

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

        self.secrets = (manifest.secrets ?? []).map {
            SecretMeta(name: $0.name, required: $0.required ?? false, howToObtain: $0.howToObtain)
        }
    }

    init(network: Bool = false, allowHostFileImport: Bool = false, exposedPorts: [UInt16] = [], secrets: [SecretMeta] = []) {
        self.network = network
        self.allowHostFileImport = allowHostFileImport
        self.exposedPorts = exposedPorts
        self.secrets = secrets
    }

    // MARK: - Codable (backward-compat: old data had `requiredSecrets: [String]`, not `secrets`)

    private enum CodingKeys: String, CodingKey {
        case network, allowHostFileImport, exposedPorts, secrets
        case legacyRequiredSecrets = "requiredSecrets"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        network = try container.decodeIfPresent(Bool.self, forKey: .network) ?? false
        allowHostFileImport = try container.decodeIfPresent(Bool.self, forKey: .allowHostFileImport) ?? false
        exposedPorts = try container.decodeIfPresent([UInt16].self, forKey: .exposedPorts) ?? []
        if let existing = try container.decodeIfPresent([SecretMeta].self, forKey: .secrets) {
            secrets = existing
        } else {
            // Migrate from pre-secrets format: requiredSecrets was a [String]
            let oldNames = try container.decodeIfPresent([String].self, forKey: .legacyRequiredSecrets) ?? []
            secrets = oldNames.map { SecretMeta(name: $0, required: true, howToObtain: nil) }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(network, forKey: .network)
        try container.encode(allowHostFileImport, forKey: .allowHostFileImport)
        try container.encode(exposedPorts, forKey: .exposedPorts)
        try container.encode(secrets, forKey: .secrets)
    }
}
