import Foundation
import os

private let logger = Logger(subsystem: "ninja.gil.VibeHost", category: "Lifecycle")

/// Manages project runtime lifecycle — importing, starting, stopping containers inside the Vibe VM.
actor ProjectLifecycleManager {

    struct ManagedState {
        let projectId: String
        var status: RunStatus
        var services: [ServiceRunState]
        var networkName: String
        /// Path inside the VM's virtio-fs share where app files are extracted.
        var vmProjectPath: String
    }

    struct ServiceRunState {
        let name: String
        let image: String
        let command: [String]
        let containerName: String
        let containerPort: UInt16
        var hostPort: UInt16
        var running: Bool
    }

    enum RunStatus: String {
        case stopped, starting, running, stopping, error
    }

    private var states: [UUID: ManagedState] = [:]

    /// Ensure the VM is running.
    func checkRuntime() async -> Bool {
        do {
            try await VMManager.shared.ensureReady()
            try await ContainerRuntimeClient.check()
            return true
        } catch {
            logger.error("Runtime check failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Prepare a project — extract files to VM shared dir, resolve ports.
    func prepare(project: Project) async throws -> ManagedState {
        let projectTag = UUID().uuidString.prefix(8).lowercased()
        let networkName = "vibe-net-\(projectTag)"

        // Ensure VM is ready before doing anything
        try await VMManager.shared.ensureReady()

        // Get the package data
        let cacheURL = StorageManager.packageCacheDir
            .appendingPathComponent(project.packageCachePath, isDirectory: true)
            .appendingPathComponent("package.vibeapp")
        let packageData: Data

        if FileManager.default.fileExists(atPath: cacheURL.path) {
            packageData = try Data(contentsOf: cacheURL)
        } else if let origPath = project.originalPackagePath {
            packageData = try Data(contentsOf: URL(fileURLWithPath: origPath))
            // Re-populate cache so future launches don't need the original path
            _ = try? StorageManager.cachePackage(data: packageData)
        } else {
            throw DockerError.commandFailed("Package not found in cache or original path")
        }

        // Extract app files to the VM shared directory so the VM can see them
        let vmSharedDir = await VMManager.shared.sharedDir
        let extractDir = vmSharedDir.appendingPathComponent("vibe-\(projectTag)", isDirectory: true)
        let pkg = try PackageExtractor.extract(data: packageData)
        try PackageExtractor.extractAppFiles(from: packageData, to: extractDir)
        logger.info("Extracted to shared dir: \(extractDir.path)")

        // Inside the VM, the shared dir is mounted at /vibe-shared
        let vmProjectPath = "/vibe-shared/vibe-\(projectTag)"

        // Build service states from manifest
        var services: [ServiceRunState] = []
        for svc in pkg.appManifest.services ?? [] {
            let image = svc.image ?? "alpine:latest"
            let command = svc.command ?? []
            let containerPort = svc.ports?.first?.container ?? 0

            let hostPort: UInt16 = containerPort > 0
                ? await ContainerRuntimeClient.findAvailablePort(preferred: containerPort)
                : 0

            services.append(ServiceRunState(
                name: svc.name,
                image: image,
                command: command,
                containerName: "vibe-\(projectTag)-\(svc.name)",
                containerPort: containerPort,
                hostPort: hostPort,
                running: false
            ))
        }

        let state = ManagedState(
            projectId: "vibe-\(projectTag)",
            status: .stopped,
            services: services,
            networkName: networkName,
            vmProjectPath: vmProjectPath
        )

        states[project.id] = state
        return state
    }

    /// Start all containers for a project.
    func start(projectId: UUID) async throws -> ManagedState {
        guard var state = states[projectId] else {
            throw DockerError.commandFailed("Project not found in lifecycle manager")
        }

        state.status = .starting
        states[projectId] = state

        // Re-resolve ports at start time
        for i in state.services.indices {
            if state.services[i].containerPort > 0 {
                state.services[i].hostPort = await ContainerRuntimeClient.findAvailablePort(
                    preferred: state.services[i].containerPort
                )
                logger.info("Port for \(state.services[i].name): \(state.services[i].containerPort) → \(state.services[i].hostPort)")
            }
        }

        // Start containers using host networking — CNI bridge is not available in
        // linux-virt kernel. Containers share the VM's network namespace directly,
        // so containerPort IS the VM port. The vsock bridge then maps host→VM.
        for svc in state.services {
            do {
                try await ContainerRuntimeClient.pullImage(svc.image)
            } catch {
                logger.warning("Failed to pull \(svc.image), trying local: \(error.localizedDescription)")
            }

            let spec = ContainerSpec(
                name: svc.containerName,
                image: svc.image,
                command: svc.command,
                env: ["VIBE_PROJECT_ID": state.projectId],
                ports: [],        // not needed with --network host
                volumes: [DockerVolumeMount(
                    hostPath: state.vmProjectPath,
                    containerPath: "/app"
                )],
                workingDir: "/app",
                network: "host",  // bypass CNI; container port = VM port
                labels: [
                    "vibe.project": state.projectId,
                    "vibe.service": svc.name
                ]
            )

            _ = try await ContainerRuntimeClient.runContainer(spec)
        }

        // Forward host TCP:hostPort → VM NAT IP:containerPort directly.
        // The VM's NAT IP is already used for SSH — guaranteed reachable.
        let vmIP = await VMManager.shared.vmIP ?? "127.0.0.1"
        for svc in state.services where svc.containerPort > 0 {
            do {
                try await VMManager.shared.addTCPBridge(
                    localPort: svc.hostPort,
                    remoteHost: vmIP,
                    remotePort: svc.containerPort
                )
            } catch {
                logger.warning("Bridge failed for \(svc.name): \(error.localizedDescription)")
            }
        }

        for i in state.services.indices {
            state.services[i].running = true
        }
        state.status = .running
        states[projectId] = state
        logger.info("Project started: \(state.projectId) with \(state.services.count) services")

        return state
    }

    /// Stop all containers for a project.
    func stop(projectId: UUID, timeout: UInt32 = 10) async throws -> ManagedState {
        guard var state = states[projectId] else {
            throw DockerError.commandFailed("Project not found in lifecycle manager")
        }

        state.status = .stopping
        states[projectId] = state

        // Remove SSH port tunnels
        for svc in state.services where svc.hostPort > 0 {
            await VMManager.shared.removeBridge(localPort: svc.hostPort)
        }

        // Stop containers in reverse order
        for svc in state.services.reversed() {
            try? await ContainerRuntimeClient.stopContainer(name: svc.containerName, timeout: timeout)
            try? await ContainerRuntimeClient.removeContainer(name: svc.containerName)
        }

        for i in state.services.indices {
            state.services[i].running = false
        }
        state.status = .stopped
        states[projectId] = state
        logger.info("Project stopped: \(state.projectId)")

        return state
    }

    func hostPort(for projectId: UUID) -> UInt16? {
        states[projectId]?.services.first(where: { $0.hostPort > 0 })?.hostPort
    }

    func status(for projectId: UUID) -> RunStatus {
        states[projectId]?.status ?? .stopped
    }
}
