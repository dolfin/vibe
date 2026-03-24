import XCTest
@testable import VibeHost

final class StorageManagerTests: XCTestCase {

    private var testHash: String!
    private var testStateDir: URL!

    override func setUp() {
        super.setUp()
        testHash = "test-storage-\(UUID().uuidString)"
        testStateDir = StorageManager.stateDir(for: testHash)
    }

    override func tearDown() {
        super.tearDown()
        // Clean up any files written during the test
        let cacheDir = StorageManager.packageCacheDir.appendingPathComponent(testHash)
        try? FileManager.default.removeItem(at: cacheDir)
    }

    // MARK: - URL path shapes

    func testAppSupportDirContainsVibe() {
        XCTAssertTrue(StorageManager.appSupportDir.path.hasSuffix("/Vibe"))
    }

    func testPackageCacheDirIsInsideAppSupportDir() {
        XCTAssertTrue(StorageManager.packageCacheDir.path.hasPrefix(StorageManager.appSupportDir.path))
        XCTAssertTrue(StorageManager.packageCacheDir.path.hasSuffix("/package-cache"))
    }

    func testProjectsFileURLIsInsideAppSupportDir() {
        XCTAssertTrue(StorageManager.projectsFileURL.path.hasPrefix(StorageManager.appSupportDir.path))
        XCTAssertTrue(StorageManager.projectsFileURL.path.hasSuffix("/projects.json"))
    }

    func testStateDirContainsHashAndState() {
        let dir = StorageManager.stateDir(for: "abc123")
        XCTAssertTrue(dir.path.contains("abc123"))
        XCTAssertTrue(dir.path.hasSuffix("/state"))
        XCTAssertTrue(dir.path.contains("package-cache"))
    }

    func testStateDirDiffersPerHash() {
        let dir1 = StorageManager.stateDir(for: "hash1")
        let dir2 = StorageManager.stateDir(for: "hash2")
        XCTAssertNotEqual(dir1, dir2)
    }

    // MARK: - loadState with no files

    func testLoadStateReturnsEmptyForUnknownHash() {
        let result = StorageManager.loadState(for: testHash)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - stateInfo with no files

    func testStateInfoReturnsZeroForUnknownHash() {
        let info = StorageManager.stateInfo(for: testHash)
        XCTAssertEqual(info.totalBytes, 0)
        XCTAssertNil(info.lastSaved)
    }

    // MARK: - saveState / loadState round-trip

    func testSaveAndLoadStateRoundTrip() {
        let entries: [String: Data] = [
            "db": Data("db_state_data".utf8),
            "cache": Data("cache_state_data".utf8),
        ]
        StorageManager.saveState(entries, for: testHash)
        let loaded = StorageManager.loadState(for: testHash)
        XCTAssertEqual(loaded["db"], Data("db_state_data".utf8))
        XCTAssertEqual(loaded["cache"], Data("cache_state_data".utf8))
        XCTAssertEqual(loaded.count, 2)
    }

    func testSaveStateOverwritesPreviousEntry() {
        StorageManager.saveState(["vol": Data("old".utf8)], for: testHash)
        StorageManager.saveState(["vol": Data("new".utf8)], for: testHash)
        let loaded = StorageManager.loadState(for: testHash)
        XCTAssertEqual(loaded["vol"], Data("new".utf8))
    }

    func testLoadStateIgnoresNonGzFiles() throws {
        // Files without .gz extension should not be loaded
        let dir = StorageManager.stateDir(for: testHash)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("vol.txt"))
        let loaded = StorageManager.loadState(for: testHash)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testSaveEmptyStateWritesNothing() {
        StorageManager.saveState([:], for: testHash)
        let loaded = StorageManager.loadState(for: testHash)
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - stateInfo with files

    func testStateInfoReturnsSizeAndDate() {
        let data = Data(repeating: 0xAB, count: 100)
        StorageManager.saveState(["vol": data], for: testHash)
        let info = StorageManager.stateInfo(for: testHash)
        XCTAssertGreaterThan(info.totalBytes, 0)
        XCTAssertNotNil(info.lastSaved)
    }

    func testStateInfoSumsSizesAcrossVolumes() {
        StorageManager.saveState([
            "vol1": Data(repeating: 0, count: 50),
            "vol2": Data(repeating: 0, count: 50),
        ], for: testHash)
        let info = StorageManager.stateInfo(for: testHash)
        // Each file is at least 50 bytes; combined should be >= 100
        XCTAssertGreaterThanOrEqual(info.totalBytes, 100)
    }

    // MARK: - loadProjects

    func testLoadProjectsReturnsArray() {
        // Just verify it returns a non-crashing result (content depends on user data)
        let projects = StorageManager.loadProjects()
        XCTAssertNotNil(projects) // [Project] is never nil
    }
}
