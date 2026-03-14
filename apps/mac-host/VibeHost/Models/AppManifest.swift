import Foundation
import Yams

/// Swift mirror of the Rust Manifest struct.
struct AppManifest: Codable {
    let kind: String
    let id: String?
    let name: String?
    let version: String?
    let icon: String?
    let runtime: RuntimeConfig?
    let services: [ServiceConfig]?
    let state: StateConfig?
    let security: SecurityConfig?
    let secrets: [SecretConfig]?
    let publisher: PublisherConfig?

    struct RuntimeConfig: Codable {
        let mode: String
        let composeFile: String?
    }

    struct ServiceConfig: Codable {
        let name: String
        let image: String?
        let command: [String]?
        let env: [String: String]?
        let ports: [PortConfig]?
        let mounts: [MountConfig]?
        let stateVolumes: [String]?
        let dependOn: [String]?
    }

    struct PortConfig: Codable {
        let container: UInt16
        let hostExposure: String?
    }

    struct MountConfig: Codable {
        let source: String
        let target: String
    }

    struct StateConfig: Codable {
        let autosave: Bool?
        let autosaveDebounceSeconds: Int?
        let retention: RetentionPolicy?
        let volumes: [VolumeConfig]?

        struct RetentionPolicy: Codable {
            let maxSnapshots: Int?
        }

        struct VolumeConfig: Codable {
            let name: String
            let consistency: String?
        }
    }

    struct SecurityConfig: Codable {
        let network: Bool?
        let allowHostFileImport: Bool?
    }

    struct SecretConfig: Codable {
        let name: String
        let required: Bool?
    }

    struct PublisherConfig: Codable {
        let name: String?
        let signing: SigningConfig?

        struct SigningConfig: Codable {
            let scheme: String?
            let signatureFile: String?
            let publicKeyFile: String?
        }
    }

    /// Parse from JSON data.
    /// Note: Rust's serde serializes with `rename_all = "camelCase"`, which
    /// already matches Swift's default property naming — no key conversion needed.
    static func fromJSON(_ data: Data) throws -> AppManifest {
        return try JSONDecoder().decode(AppManifest.self, from: data)
    }

    /// Parse from YAML string.
    static func fromYAML(_ yaml: String) throws -> AppManifest {
        let decoder = YAMLDecoder()
        return try decoder.decode(AppManifest.self, from: yaml)
    }
}
