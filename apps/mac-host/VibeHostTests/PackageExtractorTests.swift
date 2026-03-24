import XCTest
import ZIPFoundation
@testable import VibeHost

final class PackageExtractorTests: XCTestCase {

    // MARK: - extract(data:) — success

    func testExtractValidPackageWithoutSignature() throws {
        let pkgManifestJSON = """
        {"format_version":"1","app_id":"com.example","app_version":"1.0.0",
         "created_at":"2026-01-01T00:00:00Z","files":{}}
        """
        let appManifestJSON = """
        {"kind":"vibe.app/v1","id":"com.example","name":"Test","version":"1.0.0"}
        """
        let archiveData = try makeVibeAppZIP(pkgManifest: pkgManifestJSON, appManifest: appManifestJSON)
        let pkg = try PackageExtractor.extract(data: archiveData)
        XCTAssertEqual(pkg.packageManifest.appId, "com.example")
        XCTAssertEqual(pkg.appManifest.id, "com.example")
        XCTAssertNil(pkg.signature)
        XCTAssertFalse(pkg.archiveData.isEmpty)
    }

    func testExtractValidPackageWithSignature() throws {
        let pkgManifestJSON = """
        {"format_version":"1","app_id":"com.signed","app_version":"2.0.0",
         "created_at":"2026-01-01T00:00:00Z","files":{}}
        """
        let appManifestJSON = """
        {"kind":"vibe.app/v1","id":"com.signed","name":"Signed","version":"2.0.0"}
        """
        let sigData = Data(repeating: 0xAB, count: 64)
        let archiveData = try makeVibeAppZIP(
            pkgManifest: pkgManifestJSON,
            appManifest: appManifestJSON,
            signature: sigData
        )
        let pkg = try PackageExtractor.extract(data: archiveData)
        XCTAssertEqual(pkg.packageManifest.appId, "com.signed")
        XCTAssertNotNil(pkg.signature)
        XCTAssertEqual(pkg.signature?.count, 64)
    }

    // MARK: - extract(data:) — errors

    func testExtractMissingPackageManifest() throws {
        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        try addEntry(to: archive, name: "_vibe_app_manifest.json",
                     data: Data("""
                     {"kind":"vibe.app/v1","id":"x","name":"X","version":"1.0.0"}
                     """.utf8))
        let archiveData = archive.data!
        XCTAssertThrowsError(try PackageExtractor.extract(data: archiveData)) { error in
            guard case PackageExtractor.ExtractionError.missingPackageManifest = error else {
                XCTFail("Expected missingPackageManifest, got \(error)")
                return
            }
        }
    }

    func testExtractMissingAppManifest() throws {
        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        try addEntry(to: archive, name: "_vibe_package_manifest.json",
                     data: Data("""
                     {"format_version":"1","app_id":"x","app_version":"1.0.0",
                      "created_at":"now","files":{}}
                     """.utf8))
        let archiveData = archive.data!
        XCTAssertThrowsError(try PackageExtractor.extract(data: archiveData)) { error in
            guard case PackageExtractor.ExtractionError.missingAppManifest = error else {
                XCTFail("Expected missingAppManifest, got \(error)")
                return
            }
        }
    }

    func testExtractInvalidPackageManifestJSON() throws {
        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        try addEntry(to: archive, name: "_vibe_package_manifest.json", data: Data("not json".utf8))
        try addEntry(to: archive, name: "_vibe_app_manifest.json",
                     data: Data("""
                     {"kind":"vibe.app/v1","id":"x","name":"X","version":"1.0.0"}
                     """.utf8))
        let archiveData = archive.data!
        XCTAssertThrowsError(try PackageExtractor.extract(data: archiveData)) { error in
            guard case PackageExtractor.ExtractionError.invalidPackageManifest = error else {
                XCTFail("Expected invalidPackageManifest, got \(error)")
                return
            }
        }
    }

    func testExtractInvalidAppManifestJSON() throws {
        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        try addEntry(to: archive, name: "_vibe_package_manifest.json",
                     data: Data("""
                     {"format_version":"1","app_id":"x","app_version":"1.0.0",
                      "created_at":"now","files":{}}
                     """.utf8))
        try addEntry(to: archive, name: "_vibe_app_manifest.json", data: Data("INVALID".utf8))
        let archiveData = archive.data!
        XCTAssertThrowsError(try PackageExtractor.extract(data: archiveData)) { error in
            guard case PackageExtractor.ExtractionError.invalidAppManifest = error else {
                XCTFail("Expected invalidAppManifest, got \(error)")
                return
            }
        }
    }

    // MARK: - extractFile(named:from:)

    func testExtractFileExisting() throws {
        let content = Data("file content here".utf8)
        let archiveData = try makeSimpleZIP(files: ["readme.txt": content])
        let extracted = try PackageExtractor.extractFile(named: "readme.txt", from: archiveData)
        XCTAssertEqual(extracted, content)
    }

    func testExtractFileNonExistent() throws {
        let archiveData = try makeSimpleZIP(files: ["exists.txt": Data("hello".utf8)])
        let result = try PackageExtractor.extractFile(named: "does_not_exist.txt", from: archiveData)
        XCTAssertNil(result)
    }

    func testExtractFileFromInvalidData() throws {
        let result = try PackageExtractor.extractFile(named: "any.txt", from: Data("not a zip".utf8))
        XCTAssertNil(result)
    }

    // MARK: - extractStateEntries / extractInitialStateEntries

    func testExtractStateEntriesFindsEntries() throws {
        let tarData1 = Data("tar_content_db".utf8)
        let tarData2 = Data("tar_content_cache".utf8)
        let archiveData = try makeSimpleZIP(files: [
            "_vibe_state/db.tar.gz": tarData1,
            "_vibe_state/cache.tar.gz": tarData2,
            "other.txt": Data("unrelated".utf8),
        ])
        let entries = PackageExtractor.extractStateEntries(from: archiveData)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries["db"], tarData1)
        XCTAssertEqual(entries["cache"], tarData2)
    }

    func testExtractStateEntriesEmpty() throws {
        let archiveData = try makeSimpleZIP(files: ["file.txt": Data("hello".utf8)])
        let entries = PackageExtractor.extractStateEntries(from: archiveData)
        XCTAssertTrue(entries.isEmpty)
    }

    func testExtractStateEntriesFromInvalidData() {
        let entries = PackageExtractor.extractStateEntries(from: Data("bad".utf8))
        XCTAssertTrue(entries.isEmpty)
    }

    func testExtractInitialStateEntriesFindsEntries() throws {
        let tarData = Data("initial_state_data".utf8)
        let archiveData = try makeSimpleZIP(files: [
            "_vibe_initial_state/pgdata.tar.gz": tarData,
        ])
        let entries = PackageExtractor.extractInitialStateEntries(from: archiveData)
        XCTAssertEqual(entries["pgdata"], tarData)
    }

    func testExtractInitialStateEntriesIgnoresStateEntries() throws {
        let archiveData = try makeSimpleZIP(files: [
            "_vibe_state/vol.tar.gz": Data("state".utf8),
            "_vibe_initial_state/vol.tar.gz": Data("initial".utf8),
        ])
        let initialEntries = PackageExtractor.extractInitialStateEntries(from: archiveData)
        let stateEntries = PackageExtractor.extractStateEntries(from: archiveData)
        XCTAssertEqual(initialEntries.count, 1)
        XCTAssertEqual(stateEntries.count, 1)
        XCTAssertEqual(initialEntries["vol"], Data("initial".utf8))
        XCTAssertEqual(stateEntries["vol"], Data("state".utf8))
    }

    // MARK: - rebuildWithState

    func testRebuildWithStateAddsNewStateEntries() throws {
        let baseArchive = try makeSimpleZIP(files: [
            "app.txt": Data("app content".utf8),
        ])
        let newState: [String: Data] = ["mydb": Data("db_state".utf8)]
        let rebuilt = try PackageExtractor.rebuildWithState(baseData: baseArchive, stateEntries: newState)

        // The rebuilt archive should contain the state entry
        let stateEntries = PackageExtractor.extractStateEntries(from: rebuilt)
        XCTAssertEqual(stateEntries["mydb"], Data("db_state".utf8))
    }

    func testRebuildWithStateStripsOldStateEntries() throws {
        let baseArchive = try makeSimpleZIP(files: [
            "app.txt": Data("app content".utf8),
            "_vibe_state/old.tar.gz": Data("old state".utf8),
        ])
        let newState: [String: Data] = ["fresh": Data("fresh state".utf8)]
        let rebuilt = try PackageExtractor.rebuildWithState(baseData: baseArchive, stateEntries: newState)

        let stateEntries = PackageExtractor.extractStateEntries(from: rebuilt)
        XCTAssertNil(stateEntries["old"], "Old state entry should be stripped")
        XCTAssertNotNil(stateEntries["fresh"], "New state entry should be present")
    }

    func testRebuildWithStatePreservesNonStateFiles() throws {
        let baseArchive = try makeSimpleZIP(files: [
            "manifest.json": Data("{\"key\":\"value\"}".utf8),
            "_vibe_state/old.tar.gz": Data("old".utf8),
        ])
        let rebuilt = try PackageExtractor.rebuildWithState(baseData: baseArchive, stateEntries: [:])

        let extracted = try PackageExtractor.extractFile(named: "manifest.json", from: rebuilt)
        XCTAssertEqual(extracted, Data("{\"key\":\"value\"}".utf8))
    }

    // MARK: - extractAppFiles — path traversal

    func testExtractAppFilesRejectsPathTraversal() throws {
        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        let content = Data("evil".utf8)
        try addEntry(to: archive, name: "../escape.txt", data: content)
        let archiveData = archive.data!

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        XCTAssertThrowsError(try PackageExtractor.extractAppFiles(from: archiveData, to: tmpDir)) { error in
            guard case PackageExtractor.ExtractionError.pathTraversal = error else {
                XCTFail("Expected pathTraversal, got \(error)")
                return
            }
        }
    }

    func testExtractAppFilesSkipsVibeMetadata() throws {
        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        try addEntry(to: archive, name: "_vibe_package_manifest.json", data: Data("meta".utf8))
        try addEntry(to: archive, name: "app.txt", data: Data("app content".utf8))
        let archiveData = archive.data!

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try PackageExtractor.extractAppFiles(from: archiveData, to: tmpDir)

        let appFile = tmpDir.appendingPathComponent("app.txt")
        let metaFile = tmpDir.appendingPathComponent("_vibe_package_manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaFile.path))
    }

    // MARK: - Error descriptions

    func testExtractionErrorDescriptions() {
        let cases: [(PackageExtractor.ExtractionError, String)] = [
            (.missingPackageManifest, "Package is missing _vibe_package_manifest.json"),
            (.missingAppManifest, "Package is missing _vibe_app_manifest.json"),
            (.invalidPackageManifest("detail"), "Failed to parse _vibe_package_manifest.json: detail"),
            (.invalidAppManifest("oops"), "Failed to parse _vibe_app_manifest.json: oops"),
            (.tarExtractionFailed("vol1"), "Failed to extract state tarball for volume 'vol1'"),
            (.rebuildFailed, "Failed to rebuild package archive"),
            (.pathTraversal("../evil"), "Package contains a path traversal entry: '../evil'"),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(error.errorDescription, expected, "Wrong description for \(error)")
        }
    }
}

// MARK: - Test ZIP helpers (shared across test files)

func makeVibeAppZIP(
    pkgManifest: String,
    appManifest: String,
    signature: Data? = nil,
    extraFiles: [String: Data] = [:]
) throws -> Data {
    let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
    try addEntry(to: archive, name: "_vibe_package_manifest.json", data: Data(pkgManifest.utf8))
    try addEntry(to: archive, name: "_vibe_app_manifest.json", data: Data(appManifest.utf8))
    if let sig = signature {
        try addEntry(to: archive, name: "_vibe_signature.sig", data: sig)
    }
    for (name, data) in extraFiles {
        try addEntry(to: archive, name: name, data: data)
    }
    return archive.data!
}

func makeMinimalVibeAppZIP(files: [String: Data]) throws -> Data {
    let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
    try addEntry(to: archive, name: "_vibe_package_manifest.json",
                 data: Data("""
                 {"format_version":"1","app_id":"com.test","app_version":"1.0.0",
                  "created_at":"2026-01-01T00:00:00Z","files":{}}
                 """.utf8))
    try addEntry(to: archive, name: "_vibe_app_manifest.json",
                 data: Data("""
                 {"kind":"vibe.app/v1","id":"com.test","name":"Test","version":"1.0.0"}
                 """.utf8))
    for (name, data) in files {
        try addEntry(to: archive, name: name, data: data)
    }
    return archive.data!
}

func makeSimpleZIP(files: [String: Data]) throws -> Data {
    let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
    for (name, data) in files {
        try addEntry(to: archive, name: name, data: data)
    }
    return archive.data!
}

func addEntry(to archive: Archive, name: String, data: Data) throws {
    let captured = Data(data)
    try archive.addEntry(
        with: name,
        type: .file,
        uncompressedSize: Int64(captured.count),
        compressionMethod: .none,
        provider: { pos, size in
            let start = Int(pos)
            guard start < captured.count else { return Data() }
            return Data(captured[start..<min(start + size, captured.count)])
        }
    )
}
