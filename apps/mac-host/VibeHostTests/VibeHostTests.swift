import XCTest
import CryptoKit
@testable import VibeHost

final class VibeHostTests: XCTestCase {

    /// Cross-language test vector: must produce the same package hash as the
    /// Rust test `cross_language_package_hash_vector` in libs/signing/src/lib.rs.
    func testCrossLanguagePackageHashVector() throws {
        let fileDigests: [String: String] = [
            "file_a.txt": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            "file_b.txt": "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7",
        ]

        let hash = try PackageVerifier.computePackageHash(fileDigests: fileDigests)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(
            hashHex,
            "d81e92910f937cc88964af9f60f14581ec28734e252dadb66e37bed5f67d6fa4"
        )
    }

    func testTrustStatusUnsigned() {
        let manifest = PackageManifest(
            formatVersion: "1",
            appId: "com.test",
            appVersion: "1.0.0",
            createdAt: "2024-01-01T00:00:00Z",
            files: [:]
        )
        let appManifest = try! AppManifest.fromJSON(
            Data("""
            {"kind": "vibe.app/v1", "id": "com.test", "name": "Test", "version": "1.0.0"}
            """.utf8)
        )
        let pkg = VibePackage(
            packageManifest: manifest,
            appManifest: appManifest,
            signature: nil,
            archiveData: Data()
        )
        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: nil)
        XCTAssertEqual(result.status, .unsigned)
    }

    // MARK: - Decode real demo package JSON

    func testDecodePackageManifest() throws {
        let json = """
        {
          "format_version": "1",
          "app_id": "com.example.static-site",
          "app_version": "1.0.0",
          "created_at": "2026-03-14T05:54:56Z",
          "files": {
            "_vibe_app_manifest.json": "b159c2f5cb52ae3d40d191f574dcf90e1c5c76fa1b7a52b8f54dfedac650d532",
            "vibe.yaml": "7c05f2906519125c5a7fc3d79df0d1a50b9baff504c2565058b30a2bafbb0ab8"
          }
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(PackageManifest.self, from: json)
        XCTAssertEqual(manifest.appId, "com.example.static-site")
        XCTAssertEqual(manifest.formatVersion, "1")
        XCTAssertEqual(manifest.files.count, 2)
    }

    func testDecodeAppManifest() throws {
        let json = """
        {
          "kind": "vibe.app/v1",
          "id": "com.example.static-site",
          "name": "Static Website",
          "version": "1.0.0",
          "icon": "assets/icon.png",
          "services": [
            {
              "name": "web",
              "image": "nginx:alpine",
              "ports": [
                {
                  "container": 80
                }
              ],
              "mounts": [
                {
                  "source": "public",
                  "target": "/usr/share/nginx/html"
                }
              ]
            }
          ],
          "security": {
            "network": false
          },
          "publisher": {
            "name": "Vibe Examples"
          }
        }
        """.data(using: .utf8)!

        let manifest = try AppManifest.fromJSON(json)
        XCTAssertEqual(manifest.id, "com.example.static-site")
        XCTAssertEqual(manifest.name, "Static Website")
        XCTAssertEqual(manifest.services?.count, 1)
        XCTAssertEqual(manifest.services?.first?.ports?.first?.container, 80)
        XCTAssertEqual(manifest.security?.network, false)
    }

    func testDecodeAppManifestWithDependOn() throws {
        let json = """
        {
          "kind": "vibe.app/v1",
          "id": "com.example.python-api",
          "name": "Python API",
          "version": "1.0.0",
          "services": [
            {
              "name": "api",
              "image": "python:3.12-slim",
              "ports": [{"container": 8000}],
              "dependOn": ["redis"]
            },
            {
              "name": "redis",
              "image": "redis:7-alpine",
              "ports": [{"container": 6379}]
            }
          ],
          "security": {"network": true},
          "secrets": [{"name": "API_SECRET", "required": true}]
        }
        """.data(using: .utf8)!

        let manifest = try AppManifest.fromJSON(json)
        XCTAssertEqual(manifest.services?.count, 2)
        XCTAssertEqual(manifest.services?.first?.dependOn, ["redis"])
        XCTAssertEqual(manifest.secrets?.first?.name, "API_SECRET")
    }
}
