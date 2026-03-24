import XCTest
@testable import VibeHost

final class AppManifestTests: XCTestCase {

    // MARK: - fromJSON

    func testFromJSONMinimalManifest() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.minimal","name":"Min","version":"0.1.0"}
        """.utf8))
        XCTAssertEqual(manifest.kind, "vibe.app/v1")
        XCTAssertEqual(manifest.id, "com.minimal")
        XCTAssertEqual(manifest.name, "Min")
        XCTAssertEqual(manifest.version, "0.1.0")
        XCTAssertNil(manifest.icon)
        XCTAssertNil(manifest.services)
        XCTAssertNil(manifest.security)
        XCTAssertNil(manifest.secrets)
        XCTAssertNil(manifest.state)
        XCTAssertNil(manifest.publisher)
        XCTAssertNil(manifest.ui)
    }

    func testFromJSONKindOnly() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1"}
        """.utf8))
        XCTAssertEqual(manifest.kind, "vibe.app/v1")
        XCTAssertNil(manifest.id)
    }

    func testFromJSONWithIcon() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","icon":"assets/icon.png"}
        """.utf8))
        XCTAssertEqual(manifest.icon, "assets/icon.png")
    }

    func testFromJSONServiceWithAllFields() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1",
         "services":[{
           "name":"api",
           "image":"python:3.12",
           "command":["python","-m","flask","run"],
           "env":{"FLASK_ENV":"production","PORT":"5000"},
           "ports":[{"container":5000,"hostExposure":"local"}],
           "mounts":[{"source":"app","target":"/app"}],
           "stateVolumes":["data"],
           "dependOn":["db","cache"]
         }]}
        """.utf8))
        let svc = try XCTUnwrap(manifest.services?.first)
        XCTAssertEqual(svc.name, "api")
        XCTAssertEqual(svc.image, "python:3.12")
        XCTAssertEqual(svc.command, ["python", "-m", "flask", "run"])
        XCTAssertEqual(svc.env?["FLASK_ENV"], "production")
        XCTAssertEqual(svc.env?["PORT"], "5000")
        XCTAssertEqual(svc.ports?.first?.container, 5000)
        XCTAssertEqual(svc.ports?.first?.hostExposure, "local")
        XCTAssertEqual(svc.mounts?.first?.source, "app")
        XCTAssertEqual(svc.mounts?.first?.target, "/app")
        XCTAssertEqual(svc.stateVolumes, ["data"])
        XCTAssertEqual(svc.dependOn, ["db", "cache"])
    }

    func testFromJSONSecurityConfig() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","security":{"network":true,"allowHostFileImport":true}}
        """.utf8))
        XCTAssertEqual(manifest.security?.network, true)
        XCTAssertEqual(manifest.security?.allowHostFileImport, true)
    }

    func testFromJSONStateConfig() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","state":{
          "autosave":true,
          "autosaveDebounceSeconds":30,
          "retention":{"maxSnapshots":100},
          "volumes":[{"name":"data","consistency":"postgres"}]
        }}
        """.utf8))
        let state = try XCTUnwrap(manifest.state)
        XCTAssertEqual(state.autosave, true)
        XCTAssertEqual(state.autosaveDebounceSeconds, 30)
        XCTAssertEqual(state.retention?.maxSnapshots, 100)
        XCTAssertEqual(state.volumes?.first?.name, "data")
        XCTAssertEqual(state.volumes?.first?.consistency, "postgres")
    }

    func testFromJSONSecretsConfig() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","secrets":[
          {"name":"API_KEY","required":true,"howToObtain":"https://example.com/keys"},
          {"name":"OPTIONAL"}
        ]}
        """.utf8))
        XCTAssertEqual(manifest.secrets?.count, 2)
        XCTAssertEqual(manifest.secrets?[0].name, "API_KEY")
        XCTAssertEqual(manifest.secrets?[0].required, true)
        XCTAssertEqual(manifest.secrets?[0].howToObtain, "https://example.com/keys")
        XCTAssertEqual(manifest.secrets?[1].name, "OPTIONAL")
        XCTAssertNil(manifest.secrets?[1].required)
    }

    func testFromJSONUIConfig() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","ui":{
          "showBackButton":true,
          "showForwardButton":false,
          "showReloadButton":true,
          "showHomeButton":false
        }}
        """.utf8))
        let ui = try XCTUnwrap(manifest.ui)
        XCTAssertEqual(ui.showBackButton, true)
        XCTAssertEqual(ui.showForwardButton, false)
        XCTAssertEqual(ui.showReloadButton, true)
        XCTAssertEqual(ui.showHomeButton, false)
    }

    func testFromJSONPublisherWithSigning() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","publisher":{
          "name":"Acme Corp",
          "signing":{
            "scheme":"ed25519",
            "signatureFile":"_vibe_signature.sig",
            "publicKeyFile":"signing.pub"
          }
        }}
        """.utf8))
        XCTAssertEqual(manifest.publisher?.name, "Acme Corp")
        XCTAssertEqual(manifest.publisher?.signing?.scheme, "ed25519")
        XCTAssertEqual(manifest.publisher?.signing?.signatureFile, "_vibe_signature.sig")
        XCTAssertEqual(manifest.publisher?.signing?.publicKeyFile, "signing.pub")
    }

    func testFromJSONRuntimeConfig() throws {
        let manifest = try AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","runtime":{"mode":"compose","composeFile":"docker-compose.yml"}}
        """.utf8))
        XCTAssertEqual(manifest.runtime?.mode, "compose")
        XCTAssertEqual(manifest.runtime?.composeFile, "docker-compose.yml")
    }

    func testFromJSONThrowsOnInvalidData() {
        XCTAssertThrowsError(try AppManifest.fromJSON(Data("not json".utf8)))
    }

    // MARK: - fromYAML

    func testFromYAMLBasic() throws {
        let yaml = """
        kind: vibe.app/v1
        id: com.example.yaml
        name: YAML App
        version: 2.0.0
        """
        let manifest = try AppManifest.fromYAML(yaml)
        XCTAssertEqual(manifest.kind, "vibe.app/v1")
        XCTAssertEqual(manifest.id, "com.example.yaml")
        XCTAssertEqual(manifest.name, "YAML App")
        XCTAssertEqual(manifest.version, "2.0.0")
    }

    func testFromYAMLWithServices() throws {
        let yaml = """
        kind: vibe.app/v1
        id: com.example.multi
        name: Multi Service
        version: 1.0.0
        services:
          - name: web
            image: nginx:alpine
            ports:
              - container: 80
            dependOn:
              - api
          - name: api
            image: node:20-alpine
            command: ["node", "server.js"]
            ports:
              - container: 3000
        security:
          network: true
        """
        let manifest = try AppManifest.fromYAML(yaml)
        XCTAssertEqual(manifest.services?.count, 2)
        XCTAssertEqual(manifest.services?[0].name, "web")
        XCTAssertEqual(manifest.services?[0].dependOn, ["api"])
        XCTAssertEqual(manifest.services?[1].name, "api")
        XCTAssertEqual(manifest.services?[1].command, ["node", "server.js"])
        XCTAssertEqual(manifest.security?.network, true)
    }

    func testFromYAMLWithState() throws {
        let yaml = """
        kind: vibe.app/v1
        id: com.example.stateful
        name: Stateful
        version: 1.0.0
        state:
          autosave: true
          autosaveDebounceSeconds: 60
          retention:
            maxSnapshots: 50
          volumes:
            - name: pgdata
              consistency: postgres
        """
        let manifest = try AppManifest.fromYAML(yaml)
        XCTAssertEqual(manifest.state?.autosave, true)
        XCTAssertEqual(manifest.state?.autosaveDebounceSeconds, 60)
        XCTAssertEqual(manifest.state?.retention?.maxSnapshots, 50)
        XCTAssertEqual(manifest.state?.volumes?.first?.name, "pgdata")
        XCTAssertEqual(manifest.state?.volumes?.first?.consistency, "postgres")
    }

    func testFromYAMLWithSecrets() throws {
        let yaml = """
        kind: vibe.app/v1
        id: com.example.secrets
        name: Secrets App
        version: 1.0.0
        secrets:
          - name: STRIPE_KEY
            required: true
            howToObtain: https://stripe.com/docs/keys
          - name: OPTIONAL_WEBHOOK
        """
        let manifest = try AppManifest.fromYAML(yaml)
        XCTAssertEqual(manifest.secrets?.count, 2)
        XCTAssertEqual(manifest.secrets?[0].name, "STRIPE_KEY")
        XCTAssertEqual(manifest.secrets?[0].required, true)
        XCTAssertEqual(manifest.secrets?[0].howToObtain, "https://stripe.com/docs/keys")
        XCTAssertEqual(manifest.secrets?[1].name, "OPTIONAL_WEBHOOK")
    }
}
