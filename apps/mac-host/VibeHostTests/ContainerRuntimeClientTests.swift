import XCTest
@testable import VibeHost

final class ContainerRuntimeClientTests: XCTestCase {

    // MARK: - DockerError

    func testDockerErrorDescription() {
        let error = DockerError.commandFailed("exit code 1")
        XCTAssertEqual(error.errorDescription, "Container error: exit code 1")
    }

    func testDockerErrorDescriptionEmptyMessage() {
        XCTAssertEqual(DockerError.commandFailed("").errorDescription, "Container error: ")
    }

    // MARK: - Struct inits

    func testContainerSpecInit() {
        let spec = ContainerSpec(
            name: "web",
            image: "nginx:alpine",
            command: ["nginx", "-g", "daemon off;"],
            env: ["PORT": "80"],
            ports: [DockerPortMapping(host: 8080, container: 80)],
            volumes: [DockerVolumeMount(hostPath: "/tmp/app", containerPath: "/app")],
            workingDir: "/app",
            network: "bridge",
            labels: ["app": "web"]
        )
        XCTAssertEqual(spec.name, "web")
        XCTAssertEqual(spec.image, "nginx:alpine")
        XCTAssertEqual(spec.command, ["nginx", "-g", "daemon off;"])
        XCTAssertEqual(spec.env["PORT"], "80")
        XCTAssertEqual(spec.ports.first?.host, 8080)
        XCTAssertEqual(spec.ports.first?.container, 80)
        XCTAssertEqual(spec.volumes.first?.hostPath, "/tmp/app")
        XCTAssertEqual(spec.volumes.first?.containerPath, "/app")
        XCTAssertEqual(spec.workingDir, "/app")
        XCTAssertEqual(spec.network, "bridge")
        XCTAssertEqual(spec.labels["app"], "web")
    }

    func testDockerPortMappingInit() {
        let mapping = DockerPortMapping(host: 3000, container: 3000)
        XCTAssertEqual(mapping.host, 3000)
        XCTAssertEqual(mapping.container, 3000)
    }

    func testDockerVolumeMountInit() {
        let mount = DockerVolumeMount(hostPath: "/data", containerPath: "/var/lib/postgres")
        XCTAssertEqual(mount.hostPath, "/data")
        XCTAssertEqual(mount.containerPath, "/var/lib/postgres")
    }
}
