import XCTest
@testable import VibeHost

// MARK: - TrustStatus Tests

final class TrustStatusTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(TrustStatus.unsigned.rawValue, "unsigned")
        XCTAssertEqual(TrustStatus.newPublisher.rawValue, "newPublisher")
        XCTAssertEqual(TrustStatus.trustedByUser.rawValue, "trustedByUser")
        XCTAssertEqual(TrustStatus.verified.rawValue, "verified")
        XCTAssertEqual(TrustStatus.tampered.rawValue, "tampered")
    }

    func testInitFromRawValueAllCases() {
        XCTAssertEqual(TrustStatus(rawValue: "unsigned"), .unsigned)
        XCTAssertEqual(TrustStatus(rawValue: "newPublisher"), .newPublisher)
        XCTAssertEqual(TrustStatus(rawValue: "trustedByUser"), .trustedByUser)
        XCTAssertEqual(TrustStatus(rawValue: "verified"), .verified)
        XCTAssertEqual(TrustStatus(rawValue: "tampered"), .tampered)
    }

    func testInitFromInvalidRawValueReturnsNil() {
        XCTAssertNil(TrustStatus(rawValue: "unknown"))
        XCTAssertNil(TrustStatus(rawValue: "VERIFIED"))
        XCTAssertNil(TrustStatus(rawValue: "signed"))  // removed case
        XCTAssertNil(TrustStatus(rawValue: ""))
    }

    func testCodableRoundTripAllCases() throws {
        let statuses: [TrustStatus] = [.unsigned, .newPublisher, .trustedByUser, .verified, .tampered]
        for status in statuses {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(TrustStatus.self, from: data)
            XCTAssertEqual(decoded, status, "Round-trip failed for \(status)")
        }
    }

    func testDecodesFromJSONString() throws {
        let cases: [(String, TrustStatus)] = [
            ("\"unsigned\"", .unsigned),
            ("\"newPublisher\"", .newPublisher),
            ("\"trustedByUser\"", .trustedByUser),
            ("\"verified\"", .verified),
            ("\"tampered\"", .tampered),
        ]
        for (jsonString, expected) in cases {
            let data = Data(jsonString.utf8)
            let decoded = try JSONDecoder().decode(TrustStatus.self, from: data)
            XCTAssertEqual(decoded, expected)
        }
    }

    func testEncodesAsString() throws {
        let data = try JSONEncoder().encode(TrustStatus.verified)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "\"verified\"")
    }
}

// MARK: - VaultEntry Tests

final class VaultEntryTests: XCTestCase {

    func testInitWithDefaults() {
        let entry = VaultEntry(label: "My Key", envVarTags: ["API_KEY"])
        XCTAssertEqual(entry.label, "My Key")
        XCTAssertEqual(entry.envVarTags, ["API_KEY"])
        XCTAssertEqual(entry.notes, "")
        // id and createdAt are auto-generated; just verify they exist
        XCTAssertNotNil(entry.id)
    }

    func testInitWithAllExplicit() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let entry = VaultEntry(
            id: id,
            label: "Work Key",
            notes: "Used for work APIs",
            envVarTags: ["OPENAI_API_KEY", "OPENAI_KEY"],
            createdAt: date
        )
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.label, "Work Key")
        XCTAssertEqual(entry.notes, "Used for work APIs")
        XCTAssertEqual(entry.envVarTags, ["OPENAI_API_KEY", "OPENAI_KEY"])
        XCTAssertEqual(entry.createdAt, date)
    }

    func testEncodeDecodeRoundTrip() throws {
        let original = VaultEntry(
            id: UUID(),
            label: "Test Entry",
            notes: "Some notes",
            envVarTags: ["TAG_A", "TAG_B"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(VaultEntry.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.label, original.label)
        XCTAssertEqual(decoded.notes, original.notes)
        XCTAssertEqual(decoded.envVarTags, original.envVarTags)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMultipleEnvVarTags() {
        let entry = VaultEntry(
            label: "Stripe Key",
            envVarTags: ["STRIPE_SECRET_KEY", "STRIPE_KEY", "PAYMENT_KEY"]
        )
        XCTAssertEqual(entry.envVarTags.count, 3)
        XCTAssertTrue(entry.envVarTags.contains("STRIPE_SECRET_KEY"))
        XCTAssertTrue(entry.envVarTags.contains("PAYMENT_KEY"))
    }

    func testEmptyEnvVarTags() {
        let entry = VaultEntry(label: "No Tags", envVarTags: [])
        XCTAssertTrue(entry.envVarTags.isEmpty)
    }
}
