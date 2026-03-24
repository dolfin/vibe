import XCTest
@testable import VibeHost

final class VMManagerTests: XCTestCase {

    // MARK: - VMManager.State.label

    func testStateIdleLabel() {
        XCTAssertEqual(VMManager.State.idle.label, "Not running")
    }

    func testStateBootingLabel() {
        XCTAssertEqual(VMManager.State.booting.label, "Starting runtime…")
    }

    func testStateReadyLabel() {
        XCTAssertEqual(VMManager.State.ready.label, "Ready")
    }

    func testStateStoppingLabel() {
        XCTAssertEqual(VMManager.State.stopping.label, "Stopping…")
    }

    func testStateFailedLabel() {
        XCTAssertEqual(VMManager.State.failed("disk missing").label, "Failed: disk missing")
    }

    func testStateFailedLabelWithEmptyMessage() {
        XCTAssertEqual(VMManager.State.failed("").label, "Failed: ")
    }

    // MARK: - VMManager.State Equatable

    func testStateEquatableSameCases() {
        XCTAssertEqual(VMManager.State.idle, .idle)
        XCTAssertEqual(VMManager.State.booting, .booting)
        XCTAssertEqual(VMManager.State.ready, .ready)
        XCTAssertEqual(VMManager.State.stopping, .stopping)
    }

    func testStateFailedEquatableSameMessage() {
        XCTAssertEqual(VMManager.State.failed("err"), .failed("err"))
    }

    func testStateFailedEquatableDifferentMessages() {
        XCTAssertNotEqual(VMManager.State.failed("a"), .failed("b"))
    }

    func testStateDifferentCasesNotEqual() {
        XCTAssertNotEqual(VMManager.State.idle, .ready)
        XCTAssertNotEqual(VMManager.State.booting, .stopping)
    }

    // MARK: - VMError

    func testVMErrorBootFailedDescription() {
        let error = VMError.bootFailed("kernel not found")
        XCTAssertEqual(error.errorDescription, "VM boot failed: kernel not found")
    }

    func testVMErrorTimeoutDescription() {
        let error = VMError.timeout("SSH not ready after 60s")
        XCTAssertEqual(error.errorDescription, "VM timeout: SSH not ready after 60s")
    }

    // MARK: - SSH path helpers

    func testVibeSSHPrivateKeyPathEndsCorrectly() {
        let path = vibeSSHPrivateKeyPath()
        XCTAssertTrue(path.hasSuffix("Vibe/vm/vibe-vm.key"), "Expected path to end with Vibe/vm/vibe-vm.key, got: \(path)")
    }

    func testVibeSSHKnownHostsPathEndsCorrectly() {
        let path = vibeSSHKnownHostsPath()
        XCTAssertTrue(path.hasSuffix("Vibe/vm/known_hosts"), "Expected path to end with Vibe/vm/known_hosts, got: \(path)")
    }

    func testVibeSSHPathsAreDifferent() {
        XCTAssertNotEqual(vibeSSHPrivateKeyPath(), vibeSSHKnownHostsPath())
    }

    // MARK: - claimPort / releasePort

    func testClaimPortSucceedsFirstTime() async {
        let vm = await MainActor.run { VMManager.shared }
        let port: UInt16 = 19991
        vm.releasePort(port) // ensure clean state
        XCTAssertTrue(vm.claimPort(port))
        vm.releasePort(port) // cleanup
    }

    func testClaimPortFailsSecondTime() async {
        let vm = await MainActor.run { VMManager.shared }
        let port: UInt16 = 19992
        vm.releasePort(port)
        _ = vm.claimPort(port)
        XCTAssertFalse(vm.claimPort(port))
        vm.releasePort(port)
    }

    func testReleasePortAllowsReclaim() async {
        let vm = await MainActor.run { VMManager.shared }
        let port: UInt16 = 19993
        vm.releasePort(port)
        _ = vm.claimPort(port)
        vm.releasePort(port)
        XCTAssertTrue(vm.claimPort(port))
        vm.releasePort(port)
    }
}
