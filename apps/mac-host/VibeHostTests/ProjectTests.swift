import XCTest
@testable import VibeHost

final class ProjectTests: XCTestCase {

    private func makeProject(isEncrypted: Bool = false, publisher: String? = "Acme") -> Project {
        Project(
            id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!,
            appId: "com.test.app",
            appName: "Test App",
            appVersion: "1.2.3",
            publisher: publisher,
            trustStatus: .verified,
            capabilities: AppCapabilities(),
            packageHash: "abc123def456",
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            packageCachePath: "/tmp/cache/com.test.app",
            originalPackagePath: "/Users/user/Downloads/test.vibeapp",
            files: ["vibe.yaml": "hash1", "_vibe_app_manifest.json": "hash2"],
            formatVersion: "1",
            createdAt: "2026-01-01T00:00:00Z",
            isEncrypted: isEncrypted
        )
    }

    func testEncodeDecodeRoundTrip() throws {
        let original = makeProject()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Project.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.appId, original.appId)
        XCTAssertEqual(decoded.appName, original.appName)
        XCTAssertEqual(decoded.appVersion, original.appVersion)
        XCTAssertEqual(decoded.publisher, original.publisher)
        XCTAssertEqual(decoded.trustStatus, original.trustStatus)
        XCTAssertEqual(decoded.packageHash, original.packageHash)
        XCTAssertEqual(decoded.packageCachePath, original.packageCachePath)
        XCTAssertEqual(decoded.originalPackagePath, original.originalPackagePath)
        XCTAssertEqual(decoded.files, original.files)
        XCTAssertEqual(decoded.formatVersion, original.formatVersion)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.isEncrypted, original.isEncrypted)
    }

    func testIsEncryptedDefaultsToFalse() throws {
        // Simulate old JSON that doesn't have isEncrypted field
        let json = """
        {
          "id": "DEADBEEF-0000-0000-0000-000000000000",
          "appId": "com.legacy",
          "appName": "Legacy App",
          "appVersion": "1.0.0",
          "trustStatus": "unsigned",
          "capabilities": {"network":false,"allowHostFileImport":false,"exposedPorts":[],"secrets":[],"browserUI":{"showBackButton":false,"showForwardButton":false,"showReloadButton":false,"showHomeButton":false}},
          "packageHash": "hash",
          "importedAt": 1700000000.0,
          "packageCachePath": "/cache/path",
          "files": {},
          "formatVersion": "1",
          "createdAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let project = try JSONDecoder().decode(Project.self, from: json)
        XCTAssertFalse(project.isEncrypted)
    }

    func testIsEncryptedTrue() throws {
        let original = makeProject(isEncrypted: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertTrue(decoded.isEncrypted)
    }

    func testNilPublisher() throws {
        let original = makeProject(publisher: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertNil(decoded.publisher)
    }

    func testNilOriginalPackagePath() throws {
        let project = Project(
            id: UUID(),
            appId: "com.test",
            appName: "Test",
            appVersion: "1.0.0",
            publisher: nil,
            trustStatus: .unsigned,
            capabilities: AppCapabilities(),
            packageHash: "hash",
            importedAt: Date(),
            packageCachePath: "/cache",
            originalPackagePath: nil,
            files: [:],
            formatVersion: "1",
            createdAt: "2026-01-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertNil(decoded.originalPackagePath)
    }

    func testAllTrustStatuses() throws {
        for status in [TrustStatus.unsigned, .newPublisher, .trustedByUser, .verified, .tampered] {
            var project = makeProject()
            project.trustStatus = status
            let data = try JSONEncoder().encode(project)
            let decoded = try JSONDecoder().decode(Project.self, from: data)
            XCTAssertEqual(decoded.trustStatus, status)
        }
    }
}
