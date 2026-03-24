import XCTest
@testable import VibeHost

final class AppCapabilitiesTests: XCTestCase {

    // MARK: - init(from manifest:)

    func testInitNetworkTrue() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0",
         "security":{"network":true}}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertTrue(caps.network)
    }

    func testInitNetworkFalse() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0",
         "security":{"network":false}}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertFalse(caps.network)
    }

    func testInitNetworkDefaultsFalse() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0"}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertFalse(caps.network)
    }

    func testInitAllowHostFileImport() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0",
         "security":{"allowHostFileImport":true}}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertTrue(caps.allowHostFileImport)
    }

    func testInitAllowHostFileImportDefaultsFalse() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0"}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertFalse(caps.allowHostFileImport)
    }

    func testInitExtractsPortsFromMultipleServices() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0",
         "services":[
           {"name":"web","image":"nginx","ports":[{"container":80},{"container":443}]},
           {"name":"api","image":"node","ports":[{"container":3000}]}
         ]}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertEqual(Set(caps.exposedPorts), Set([80, 443, 3000]))
    }

    func testInitNoServicesGivesEmptyPorts() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0"}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertTrue(caps.exposedPorts.isEmpty)
    }

    func testInitServiceWithNoPorts() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0",
         "services":[{"name":"db","image":"postgres"}]}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertTrue(caps.exposedPorts.isEmpty)
    }

    func testInitExtractsRequiredAndOptionalSecrets() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0",
         "secrets":[
           {"name":"API_KEY","required":true,"howToObtain":"See docs"},
           {"name":"OPTIONAL_TOKEN","required":false}
         ]}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertEqual(caps.secrets.count, 2)
        XCTAssertEqual(caps.secrets[0].name, "API_KEY")
        XCTAssertTrue(caps.secrets[0].required)
        XCTAssertEqual(caps.secrets[0].howToObtain, "See docs")
        XCTAssertEqual(caps.secrets[1].name, "OPTIONAL_TOKEN")
        XCTAssertFalse(caps.secrets[1].required)
        XCTAssertNil(caps.secrets[1].howToObtain)
    }

    func testInitSecretRequiredDefaultsFalse() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0",
         "secrets":[{"name":"MY_SECRET"}]}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertFalse(caps.secrets[0].required)
    }

    func testInitBrowserUI() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0",
         "ui":{"showBackButton":true,"showForwardButton":true,"showReloadButton":false,"showHomeButton":true}}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertTrue(caps.browserUI.showBackButton)
        XCTAssertTrue(caps.browserUI.showForwardButton)
        XCTAssertFalse(caps.browserUI.showReloadButton)
        XCTAssertTrue(caps.browserUI.showHomeButton)
    }

    func testInitBrowserUIDefaultsToAllFalse() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0"}
        """.utf8))
        let caps = AppCapabilities(from: manifest)
        XCTAssertFalse(caps.browserUI.showBackButton)
        XCTAssertFalse(caps.browserUI.showForwardButton)
        XCTAssertFalse(caps.browserUI.showReloadButton)
        XCTAssertFalse(caps.browserUI.showHomeButton)
    }

    // MARK: - Computed properties

    func testRequiredSecretsFiltersCorrectly() {
        let caps = AppCapabilities(
            secrets: [
                AppCapabilities.SecretMeta(name: "A", required: true, howToObtain: nil),
                AppCapabilities.SecretMeta(name: "B", required: false, howToObtain: nil),
                AppCapabilities.SecretMeta(name: "C", required: true, howToObtain: nil),
            ]
        )
        XCTAssertEqual(caps.requiredSecrets, ["A", "C"])
    }

    func testRequiredSecretsEmptyWhenNoneRequired() {
        let caps = AppCapabilities(
            secrets: [
                AppCapabilities.SecretMeta(name: "X", required: false, howToObtain: nil),
            ]
        )
        XCTAssertTrue(caps.requiredSecrets.isEmpty)
    }

    func testDeclaredSecretsReturnsAll() {
        let caps = AppCapabilities(
            secrets: [
                AppCapabilities.SecretMeta(name: "A", required: true, howToObtain: nil),
                AppCapabilities.SecretMeta(name: "B", required: false, howToObtain: nil),
            ]
        )
        XCTAssertEqual(caps.declaredSecrets, ["A", "B"])
    }

    // MARK: - BrowserUI.hasAnyButton

    func testBrowserUIHasAnyButtonAllFalse() {
        XCTAssertFalse(AppCapabilities.BrowserUI.none.hasAnyButton)
    }

    func testBrowserUIHasAnyButtonBack() {
        let ui = AppCapabilities.BrowserUI(showBackButton: true, showForwardButton: false, showReloadButton: false, showHomeButton: false)
        XCTAssertTrue(ui.hasAnyButton)
    }

    func testBrowserUIHasAnyButtonForward() {
        let ui = AppCapabilities.BrowserUI(showBackButton: false, showForwardButton: true, showReloadButton: false, showHomeButton: false)
        XCTAssertTrue(ui.hasAnyButton)
    }

    func testBrowserUIHasAnyButtonReload() {
        let ui = AppCapabilities.BrowserUI(showBackButton: false, showForwardButton: false, showReloadButton: true, showHomeButton: false)
        XCTAssertTrue(ui.hasAnyButton)
    }

    func testBrowserUIHasAnyButtonHome() {
        let ui = AppCapabilities.BrowserUI(showBackButton: false, showForwardButton: false, showReloadButton: false, showHomeButton: true)
        XCTAssertTrue(ui.hasAnyButton)
    }

    func testBrowserUIStaticNone() {
        let none = AppCapabilities.BrowserUI.none
        XCTAssertFalse(none.showBackButton)
        XCTAssertFalse(none.showForwardButton)
        XCTAssertFalse(none.showReloadButton)
        XCTAssertFalse(none.showHomeButton)
        XCTAssertFalse(none.hasAnyButton)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let original = AppCapabilities(
            network: true,
            allowHostFileImport: true,
            exposedPorts: [80, 3000],
            secrets: [AppCapabilities.SecretMeta(name: "KEY", required: true, howToObtain: "check site")],
            browserUI: AppCapabilities.BrowserUI(showBackButton: true, showForwardButton: false, showReloadButton: true, showHomeButton: false)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppCapabilities.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testDecodeLegacyRequiredSecrets() throws {
        let legacyJSON = """
        {"network":false,"allowHostFileImport":false,"exposedPorts":[],
         "requiredSecrets":["API_KEY","DB_PASS"],
         "browserUI":{"showBackButton":false,"showForwardButton":false,"showReloadButton":false,"showHomeButton":false}}
        """.data(using: .utf8)!
        let caps = try JSONDecoder().decode(AppCapabilities.self, from: legacyJSON)
        XCTAssertEqual(caps.secrets.count, 2)
        XCTAssertEqual(caps.secrets[0].name, "API_KEY")
        XCTAssertTrue(caps.secrets[0].required)
        XCTAssertNil(caps.secrets[0].howToObtain)
        XCTAssertEqual(caps.secrets[1].name, "DB_PASS")
        XCTAssertTrue(caps.secrets[1].required)
    }

    func testDecodeWithMissingOptionalFields() throws {
        let minimalJSON = """
        {"network":false,"allowHostFileImport":false}
        """.data(using: .utf8)!
        let caps = try JSONDecoder().decode(AppCapabilities.self, from: minimalJSON)
        XCTAssertFalse(caps.network)
        XCTAssertFalse(caps.allowHostFileImport)
        XCTAssertTrue(caps.exposedPorts.isEmpty)
        XCTAssertTrue(caps.secrets.isEmpty)
        XCTAssertFalse(caps.browserUI.hasAnyButton)
    }

    func testDecodePrefersSectetsOverLegacyRequiredSecrets() throws {
        // When both "secrets" and "requiredSecrets" are present, "secrets" wins
        let json = """
        {"network":false,"allowHostFileImport":false,
         "secrets":[{"name":"NEW","required":true}],
         "requiredSecrets":["OLD"],
         "browserUI":{"showBackButton":false,"showForwardButton":false,"showReloadButton":false,"showHomeButton":false}}
        """.data(using: .utf8)!
        let caps = try JSONDecoder().decode(AppCapabilities.self, from: json)
        XCTAssertEqual(caps.secrets.count, 1)
        XCTAssertEqual(caps.secrets[0].name, "NEW")
    }
}
