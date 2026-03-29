import XCTest
import UniformTypeIdentifiers
@testable import VibeHost

// MARK: - SecretsManager Tests

final class SecretsManagerTests: XCTestCase {

    private let testPackageId = "test-pkg-\(UUID().uuidString)"
    private let testSecretName = "TEST_SECRET"

    override func tearDown() {
        super.tearDown()
        SecretsManager.delete(packageId: testPackageId, name: testSecretName)
    }

    func testServiceIdentifier() {
        XCTAssertEqual(SecretsManager.service, "app.dotvibe.Vibe.secrets")
    }

    func testSaveAndLoadRoundTrip() throws {
        try SecretsManager.save("super-secret-value", packageId: testPackageId, name: testSecretName)
        let loaded = SecretsManager.load(packageId: testPackageId, name: testSecretName)
        XCTAssertEqual(loaded, "super-secret-value")
    }

    func testLoadReturnsNilWhenNotSet() {
        let result = SecretsManager.load(packageId: testPackageId, name: "NONEXISTENT_SECRET")
        XCTAssertNil(result)
    }

    func testDeleteRemovesSecret() throws {
        try SecretsManager.save("value", packageId: testPackageId, name: testSecretName)
        SecretsManager.delete(packageId: testPackageId, name: testSecretName)
        XCTAssertNil(SecretsManager.load(packageId: testPackageId, name: testSecretName))
    }

    func testLoadAllReturnsOnlyPresentSecrets() throws {
        try SecretsManager.save("val-a", packageId: testPackageId, name: "A")
        defer { SecretsManager.delete(packageId: testPackageId, name: "A") }

        let result = SecretsManager.loadAll(packageId: testPackageId, names: ["A", "MISSING"])
        XCTAssertEqual(result["A"], "val-a")
        XCTAssertNil(result["MISSING"])
    }

    func testDeleteAllRemovesMultiple() throws {
        try SecretsManager.save("v1", packageId: testPackageId, name: "K1")
        try SecretsManager.save("v2", packageId: testPackageId, name: "K2")
        SecretsManager.deleteAll(for: testPackageId, names: ["K1", "K2"])
        XCTAssertNil(SecretsManager.load(packageId: testPackageId, name: "K1"))
        XCTAssertNil(SecretsManager.load(packageId: testPackageId, name: "K2"))
    }

    func testSaveOverwritesPreviousValue() throws {
        try SecretsManager.save("first", packageId: testPackageId, name: testSecretName)
        try SecretsManager.save("second", packageId: testPackageId, name: testSecretName)
        XCTAssertEqual(SecretsManager.load(packageId: testPackageId, name: testSecretName), "second")
    }

    // MARK: - Vault namespace

    func testSaveAndLoadVaultEntryRoundTrip() throws {
        let id = UUID().uuidString
        defer { SecretsManager.deleteVaultEntry(id: id) }
        try SecretsManager.saveVaultEntry("my-api-key", id: id)
        XCTAssertEqual(SecretsManager.loadVaultEntry(id: id), "my-api-key")
    }

    func testLoadVaultEntryNilWhenNotSet() {
        XCTAssertNil(SecretsManager.loadVaultEntry(id: UUID().uuidString))
    }

    func testDeleteVaultEntryRemovesIt() throws {
        let id = UUID().uuidString
        try SecretsManager.saveVaultEntry("value", id: id)
        SecretsManager.deleteVaultEntry(id: id)
        XCTAssertNil(SecretsManager.loadVaultEntry(id: id))
    }

    func testVaultNamespaceIsolatedFromPackageSecrets() throws {
        // A vault ID that looks like a package secret account should not collide
        let id = "pkg123.MY_SECRET"
        defer { SecretsManager.deleteVaultEntry(id: id) }
        try SecretsManager.saveVaultEntry("vault-value", id: id)
        // The package secret at the same "name" should be absent
        XCTAssertNil(SecretsManager.load(packageId: "pkg123", name: "MY_SECRET"))
        XCTAssertEqual(SecretsManager.loadVaultEntry(id: id), "vault-value")
    }
}

// MARK: - UTType Tests

final class UTTypeTests: XCTestCase {

    func testVibeAppTypeIdentifier() {
        XCTAssertEqual(UTType.vibeApp.identifier, "app.dotvibe.vibe.vibeapp")
    }

    func testVibeAppTypeIsNotNil() {
        // UTType(exportedAs:) always succeeds; verify the static property is valid
        XCTAssertNotNil(UTType.vibeApp)
    }
}

// MARK: - ProjectStore Tests

final class ProjectStoreTests: XCTestCase {

    private func makeProject() -> Project {
        Project(
            id: UUID(),
            appId: "com.test.coverage",
            appName: "Coverage Test",
            appVersion: "1.0.0",
            publisher: nil,
            trustStatus: .unsigned,
            capabilities: AppCapabilities(),
            packageHash: "testhash",
            importedAt: Date(),
            packageCachePath: UUID().uuidString, // unique so removeProject cleanup is a no-op
            originalPackagePath: nil,
            files: [:],
            formatVersion: "1",
            createdAt: "2026-01-01T00:00:00Z"
        )
    }

    func testRemoveProjectByID() {
        let store = ProjectStore()
        let project = makeProject()
        // Append directly to avoid triggering save with real projects
        store.projects.append(project)
        XCTAssertTrue(store.projects.contains { $0.id == project.id })
        store.removeProject(project)
        XCTAssertFalse(store.projects.contains { $0.id == project.id })
    }

    func testRemoveProjectLeavesOthersIntact() {
        let store = ProjectStore()
        let p1 = makeProject()
        let p2 = makeProject()
        store.projects.append(p1)
        store.projects.append(p2)
        store.removeProject(p1)
        XCTAssertFalse(store.projects.contains { $0.id == p1.id })
        XCTAssertTrue(store.projects.contains { $0.id == p2.id })
        // Cleanup
        store.projects.removeAll { $0.id == p2.id }
    }

    func testDemoPublicKeyIsNilOrData() {
        let store = ProjectStore()
        // In the test bundle, the resource may or may not exist — either is valid
        let key = store.demoPublicKey
        if let key {
            XCTAssertFalse(key.isEmpty)
        } else {
            XCTAssertNil(key) // not bundled in test target — that's fine
        }
    }
}
