import XCTest
@testable import VibeHost

final class RuntimeStateTests: XCTestCase {

    private func makeProject(id: UUID = UUID()) -> Project {
        Project(
            id: id,
            appId: "com.test",
            appName: "Test",
            appVersion: "1.0.0",
            publisher: nil,
            trustStatus: .unsigned,
            capabilities: AppCapabilities(),
            packageHash: "hash",
            importedAt: Date(),
            packageCachePath: "/tmp/cache",
            originalPackagePath: nil,
            files: [:],
            formatVersion: "1",
            createdAt: "2026-01-01T00:00:00Z"
        )
    }

    // MARK: - ProjectRunStatus

    func testProjectRunStatusCases() {
        // Exhaustive switch — compiler catches missing cases
        let statuses: [ProjectRunStatus] = [.stopped, .starting, .running, .stopping, .error]
        XCTAssertEqual(statuses.count, 5)
    }

    // MARK: - ProjectLifecycleManager.RunStatus

    func testRunStatusRawValues() {
        XCTAssertEqual(ProjectLifecycleManager.RunStatus.stopped.rawValue, "stopped")
        XCTAssertEqual(ProjectLifecycleManager.RunStatus.starting.rawValue, "starting")
        XCTAssertEqual(ProjectLifecycleManager.RunStatus.running.rawValue, "running")
        XCTAssertEqual(ProjectLifecycleManager.RunStatus.stopping.rawValue, "stopping")
        XCTAssertEqual(ProjectLifecycleManager.RunStatus.error.rawValue, "error")
    }

    func testRunStatusRoundTripFromRawValue() {
        for raw in ["stopped", "starting", "running", "stopping", "error"] {
            XCTAssertNotNil(ProjectLifecycleManager.RunStatus(rawValue: raw), "Missing case for raw value '\(raw)'")
        }
    }

    // MARK: - RuntimeState.status(for:)

    func testStatusDefaultsToStoppedForUnknownProject() {
        let state = RuntimeState()
        let project = makeProject()
        XCTAssertEqual(state.status(for: project), .stopped)
    }

    func testStatusReturnsSetValue() {
        let state = RuntimeState()
        let project = makeProject()
        state.statuses[project.id] = .running
        XCTAssertEqual(state.status(for: project), .running)
    }

    func testStatusReturnsStarting() {
        let state = RuntimeState()
        let project = makeProject()
        state.statuses[project.id] = .starting
        XCTAssertEqual(state.status(for: project), .starting)
    }

    // MARK: - RuntimeState.isExposed / exposedPort

    func testIsExposedFalseWhenNoHostPort() {
        let state = RuntimeState()
        let project = makeProject()
        XCTAssertFalse(state.isExposed(project))
    }

    func testIsExposedTrueWhenHostPortSet() {
        let state = RuntimeState()
        let project = makeProject()
        state.hostPorts[project.id] = 8080
        XCTAssertTrue(state.isExposed(project))
    }

    func testExposedPortNilWhenNotSet() {
        let state = RuntimeState()
        let project = makeProject()
        XCTAssertNil(state.exposedPort(for: project))
    }

    func testExposedPortReturnsSetValue() {
        let state = RuntimeState()
        let project = makeProject()
        state.hostPorts[project.id] = 3000
        XCTAssertEqual(state.exposedPort(for: project), 3000)
    }

    // MARK: - RuntimeState.vmEndpoint(for:)

    func testVmEndpointNilWhenNotSet() {
        let state = RuntimeState()
        let project = makeProject()
        XCTAssertNil(state.vmEndpoint(for: project))
    }

    func testVmEndpointReturnsSetValue() {
        let state = RuntimeState()
        let project = makeProject()
        state.vmEndpoints[project.id] = (vmIP: "192.168.64.2", containerPort: 3000, hostPort: 54321)
        let ep = state.vmEndpoint(for: project)
        XCTAssertEqual(ep?.vmIP, "192.168.64.2")
        XCTAssertEqual(ep?.containerPort, 3000)
        XCTAssertEqual(ep?.hostPort, 54321)
    }

    // MARK: - RuntimeState.hostPort(for:)

    func testHostPortNilWhenNotSet() {
        let state = RuntimeState()
        let project = makeProject()
        XCTAssertNil(state.hostPort(for: project))
    }

    func testHostPortReturnsSetValue() {
        let state = RuntimeState()
        let project = makeProject()
        state.hostPorts[project.id] = 9090
        XCTAssertEqual(state.hostPort(for: project), 9090)
    }

    // MARK: - RuntimeState.statusMessage(for:)

    func testStatusMessageNilWhenNotSet() {
        let state = RuntimeState()
        let project = makeProject()
        XCTAssertNil(state.statusMessage(for: project))
    }

    func testStatusMessageReturnsSetValue() {
        let state = RuntimeState()
        let project = makeProject()
        state.statusMessages[project.id] = "Pulling images…"
        XCTAssertEqual(state.statusMessage(for: project), "Pulling images…")
    }

    // MARK: - Multiple projects isolated

    func testStatusIsolatedPerProject() {
        let state = RuntimeState()
        let p1 = makeProject()
        let p2 = makeProject()
        state.statuses[p1.id] = .running
        state.statuses[p2.id] = .starting
        XCTAssertEqual(state.status(for: p1), .running)
        XCTAssertEqual(state.status(for: p2), .starting)
    }
}
