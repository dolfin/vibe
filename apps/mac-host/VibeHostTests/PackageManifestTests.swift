import XCTest
@testable import VibeHost

final class PackageManifestTests: XCTestCase {

    func testDecodeSnakeCaseKeys() throws {
        let json = """
        {
          "format_version": "1",
          "app_id": "com.example.app",
          "app_version": "2.3.4",
          "created_at": "2026-01-15T10:00:00Z",
          "files": {
            "vibe.yaml": "abc123",
            "_vibe_app_manifest.json": "def456"
          }
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PackageManifest.self, from: json)
        XCTAssertEqual(manifest.formatVersion, "1")
        XCTAssertEqual(manifest.appId, "com.example.app")
        XCTAssertEqual(manifest.appVersion, "2.3.4")
        XCTAssertEqual(manifest.createdAt, "2026-01-15T10:00:00Z")
        XCTAssertEqual(manifest.files.count, 2)
        XCTAssertEqual(manifest.files["vibe.yaml"], "abc123")
        XCTAssertEqual(manifest.files["_vibe_app_manifest.json"], "def456")
    }

    func testEncodeUsesSnakeCaseKeys() throws {
        let manifest = PackageManifest(
            formatVersion: "1",
            appId: "com.test",
            appVersion: "1.0.0",
            createdAt: "2026-03-01T00:00:00Z",
            files: ["file.txt": "hash"]
        )
        let data = try JSONEncoder().encode(manifest)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["format_version"], "Should encode as format_version")
        XCTAssertNotNil(json["app_id"], "Should encode as app_id")
        XCTAssertNotNil(json["app_version"], "Should encode as app_version")
        XCTAssertNotNil(json["created_at"], "Should encode as created_at")
        XCTAssertNil(json["formatVersion"], "Should NOT encode as formatVersion")
    }

    func testEncodeDecodeRoundTrip() throws {
        let original = PackageManifest(
            formatVersion: "1",
            appId: "com.roundtrip",
            appVersion: "3.2.1",
            createdAt: "2026-06-01T12:00:00Z",
            files: ["a.txt": "hash_a", "b.json": "hash_b"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PackageManifest.self, from: data)
        XCTAssertEqual(decoded.formatVersion, original.formatVersion)
        XCTAssertEqual(decoded.appId, original.appId)
        XCTAssertEqual(decoded.appVersion, original.appVersion)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.files, original.files)
    }

    func testDecodeEmptyFiles() throws {
        let json = """
        {"format_version":"1","app_id":"x","app_version":"1","created_at":"now","files":{}}
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PackageManifest.self, from: json)
        XCTAssertTrue(manifest.files.isEmpty)
    }
}
