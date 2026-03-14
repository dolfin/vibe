import Foundation

/// HTTP client for the Vibe supervisor REST API.
actor SupervisorClient {
    let baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:8090")!) {
        self.baseURL = baseURL
    }

    // MARK: - API Types

    struct ApiResponse<T: Decodable>: Decodable {
        let ok: Bool
        let data: T?
        let error: String?
    }

    struct ManagedProject: Decodable, Sendable {
        let id: String
        let appId: String
        let appName: String
        let appVersion: String
        let status: String
        let services: [ServiceState]
        let networkName: String
        let extractDir: String?

        enum CodingKeys: String, CodingKey {
            case id
            case appId = "app_id"
            case appName = "app_name"
            case appVersion = "app_version"
            case status
            case services
            case networkName = "network_name"
            case extractDir = "extract_dir"
        }
    }

    struct ServiceState: Decodable, Sendable {
        let name: String
        let image: String
        let command: [String]?
        let containerName: String
        let containerPort: UInt16
        let hostPort: UInt16
        let running: Bool

        enum CodingKeys: String, CodingKey {
            case name, image, command
            case containerName = "container_name"
            case containerPort = "container_port"
            case hostPort = "host_port"
            case running
        }
    }

    enum ClientError: LocalizedError {
        case requestFailed(String)
        case serverError(String)
        case notReachable

        var errorDescription: String? {
            switch self {
            case .requestFailed(let msg): "Request failed: \(msg)"
            case .serverError(let msg): "Server error: \(msg)"
            case .notReachable: "Supervisor not reachable. Start it with: cargo run --bin vibe-supervisor"
            }
        }
    }

    // MARK: - Health

    func isAvailable() async -> Bool {
        let url = baseURL.appendingPathComponent("healthz")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            _ = data
            return true
        } catch {
            return false
        }
    }

    // MARK: - Project Lifecycle

    func importPackage(path: String) async throws -> ManagedProject {
        let url = baseURL.appendingPathComponent("api/projects/import")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["package_path": path])

        return try await perform(request)
    }

    func startProject(id: String) async throws -> ManagedProject {
        let url = baseURL.appendingPathComponent("api/projects/\(id)/start")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        return try await perform(request)
    }

    func stopProject(id: String) async throws -> ManagedProject {
        let url = baseURL.appendingPathComponent("api/projects/\(id)/stop")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["timeout_seconds": 10])

        return try await perform(request)
    }

    func getProject(id: String) async throws -> ManagedProject {
        let url = baseURL.appendingPathComponent("api/projects/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        return try await perform(request)
    }

    func removeProject(id: String) async throws {
        let url = baseURL.appendingPathComponent("api/projects/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let _: EmptyData = try await perform(request)
    }

    // MARK: - Internal

    private struct EmptyData: Decodable {}

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.notReachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.requestFailed("invalid response")
        }

        let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary \(data.count) bytes>"

        guard !data.isEmpty else {
            throw ClientError.serverError("empty response (HTTP \(http.statusCode)) for \(request.url?.path ?? "?")")
        }

        let decoded: ApiResponse<T>
        do {
            decoded = try JSONDecoder().decode(ApiResponse<T>.self, from: data)
        } catch {
            throw ClientError.serverError("HTTP \(http.statusCode) — not JSON: \(bodyPreview)")
        }

        if !decoded.ok {
            throw ClientError.serverError(decoded.error ?? "unknown error (HTTP \(http.statusCode))")
        }

        guard let result = decoded.data else {
            throw ClientError.serverError("empty response data")
        }

        return result
    }
}
