import Foundation
import os

private let logger = Logger(subsystem: "ninja.gil.VibeHost", category: "Lifecycle")

/// Manages project runtime lifecycle — importing, starting, stopping containers inside the Vibe VM.
actor ProjectLifecycleManager {

    struct ManagedState {
        let projectId: String
        var status: RunStatus
        var services: [ServiceRunState]
        /// Path inside the VM's virtio-fs share where app files are extracted.
        var vmProjectPath: String
        /// NAT IP of the VM (set after start()).
        var vmIP: String = ""
        /// App manifest — used by snapshotState() to look up volume names.
        let appManifest: AppManifest
        /// Host-side directory where app files (and state volumes) were extracted.
        let extractDir: URL
    }

    struct ServiceRunState {
        let name: String
        let image: String
        let command: [String]
        let containerName: String
        let containerPort: UInt16
        var hostPort: UInt16
        var running: Bool
        /// Explicit mounts from the manifest (source is relative to the project dir).
        let mounts: [(source: String, target: String)]
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
        let prepareStart = Date()

        // Ensure VM is ready before doing anything
        try await VMManager.shared.ensureReady()
        logger.info("BENCH prepare[\(projectTag)]: VM ready at +\(String(format: "%.2f", -prepareStart.timeIntervalSinceNow))s")

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
        let extractStart = Date()
        let pkg = try PackageExtractor.extract(data: packageData)
        try PackageExtractor.extractAppFiles(from: packageData, to: extractDir)
        logger.info("BENCH prepare[\(projectTag)]: extraction done in \(String(format: "%.2f", -extractStart.timeIntervalSinceNow))s → \(extractDir.path)")

        // Always create volume directories declared in the manifest so the container
        // can bind-mount them and the snapshot poller has a directory to watch.
        // This is critical after a revert where no saved or initial state exists —
        // without pre-creating the directory the host path is missing, nerdctl
        // cannot bind-mount it, and latestModDate() returns nil so writes are
        // never detected and no state is ever saved.
        let declaredVolumeNames = (pkg.appManifest.state?.volumes ?? []).map { $0.name }
        for volName in declaredVolumeNames {
            let volDir = extractDir.appendingPathComponent(volName, isDirectory: true)
            try FileManager.default.createDirectory(at: volDir, withIntermediateDirectories: true)
        }

        // Restore saved state (priority), or seed from signed initial state if present.
        let savedState = StorageManager.loadState(for: project.packageCachePath)
        if !savedState.isEmpty {
            try PackageExtractor.extractStateTarballs(savedState, to: extractDir)
            logger.info("prepare[\(projectTag)]: restored \(savedState.count) saved state volume(s)")
        } else {
            let initialState = PackageExtractor.extractInitialStateEntries(from: packageData)
            if !initialState.isEmpty {
                try PackageExtractor.extractStateTarballs(initialState, to: extractDir)
                logger.info("prepare[\(projectTag)]: seeded \(initialState.count) initial state volume(s)")
            } else if !declaredVolumeNames.isEmpty {
                logger.info("prepare[\(projectTag)]: \(declaredVolumeNames.count) volume(s) start empty")
            }
        }

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

            let mounts = (svc.mounts ?? []).map { (source: $0.source, target: $0.target) }

            services.append(ServiceRunState(
                name: svc.name,
                image: image,
                command: command,
                containerName: "vibe-\(projectTag)-\(svc.name)",
                containerPort: containerPort,
                hostPort: hostPort,
                running: false,
                mounts: mounts
            ))
        }

        // Kick off image pre-pulls in parallel with the file extraction that follows.
        // ContainerRuntimeClient.pullImage() uses activePullTasks deduplication — if start()
        // calls pullImage() for the same image later, it simply awaits the in-progress task.
        let imagesToPrewarm = (pkg.appManifest.services ?? []).map { $0.image ?? "alpine:latest" }
        let prewarmStart = Date()
        logger.info("BENCH prepare[\(projectTag)]: starting pre-pull for \(imagesToPrewarm.joined(separator: ", "))")
        Task.detached { [logger] in
            await withTaskGroup(of: Void.self) { group in
                for image in imagesToPrewarm {
                    group.addTask { try? await ContainerRuntimeClient.pullImage(image) }
                }
            }
            logger.info("BENCH prewarm[\(projectTag)]: all images ready in \(String(format: "%.2f", -prewarmStart.timeIntervalSinceNow))s")
        }

        let state = ManagedState(
            projectId: "vibe-\(projectTag)",
            status: .stopped,
            services: services,
            vmProjectPath: vmProjectPath,
            appManifest: pkg.appManifest,
            extractDir: extractDir
        )

        states[project.id] = state
        return state
    }

    /// Start all containers for a project.
    func start(projectId: UUID) async throws -> ManagedState {
        guard var state = states[projectId] else {
            throw DockerError.commandFailed("Project not found in lifecycle manager")
        }

        let startTime = Date()
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

        // Capture VM IP before the container loop so socat logging and waitForServices
        // can use it immediately.
        state.vmIP = await VMManager.shared.vmIP ?? "127.0.0.1"

        for svc in state.services {
            do {
                let pullStart = Date()
                try await ContainerRuntimeClient.pullImage(svc.image)
                logger.info("BENCH start[\(state.projectId)]: pull \(svc.image) done in \(String(format: "%.2f", -pullStart.timeIntervalSinceNow))s")
            } catch {
                logger.warning("Failed to pull \(svc.image), trying local: \(error.localizedDescription)")
            }

            // Start with the default project mount at /app for workingDir access.
            // Append any explicit mounts from the manifest (e.g. nginx content dir).
            var volumes = [DockerVolumeMount(hostPath: state.vmProjectPath, containerPath: "/app")]
            for m in svc.mounts {
                volumes.append(DockerVolumeMount(
                    hostPath: "\(state.vmProjectPath)/\(m.source)",
                    containerPath: m.target
                ))
            }

            var portMappings: [DockerPortMapping] = []
            if svc.containerPort > 0 && svc.hostPort > 0 {
                portMappings.append(DockerPortMapping(host: svc.hostPort, container: svc.containerPort))
            }

            let spec = ContainerSpec(
                name: svc.containerName,
                image: svc.image,
                command: svc.command,
                env: ["VIBE_PROJECT_ID": state.projectId],
                ports: portMappings,
                volumes: volumes,
                workingDir: "/app",
                network: "bridge",
                labels: [
                    "vibe.project": state.projectId,
                    "vibe.service": svc.name
                ]
            )

            _ = try await ContainerRuntimeClient.runContainer(spec)
        }

        for i in state.services.indices {
            state.services[i].running = true
        }
        state.status = .running
        states[projectId] = state

        // Wait until services are actually accepting connections before reporting ready.
        // The container runtime returns as soon as the container starts — the application
        // inside may take additional time to bind to its port.
        await waitForServices(state: state)

        logger.info("BENCH start[\(state.projectId)]: all containers running in \(String(format: "%.2f", -startTime.timeIntervalSinceNow))s")
        logger.info("Project started: \(state.projectId) with \(state.services.count) services")

        return state
    }

    /// Poll each service port until it accepts connections or the timeout elapses.
    private func waitForServices(state: ManagedState, maxWaitSeconds: Double = 180) async {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        var pending = state.services.filter { $0.hostPort > 0 }
        guard !pending.isEmpty else { return }

        while !pending.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            var stillWaiting: [ServiceRunState] = []
            for svc in pending {
                let urlStr = "http://\(state.vmIP):\(svc.hostPort)/"
                guard let url = URL(string: urlStr) else { continue }
                var req = URLRequest(url: url, timeoutInterval: 0.5)
                req.httpMethod = "HEAD"
                if let _ = try? await session.data(for: req) {
                    logger.info("start[\(state.projectId)]: \(svc.name) ready on :\(svc.containerPort)")
                } else {
                    stillWaiting.append(svc)
                }
            }
            pending = stillWaiting
        }

        if !pending.isEmpty {
            logger.warning("start[\(state.projectId)]: timed out waiting for \(pending.map(\.name).joined(separator: ", "))")
        }
    }

    /// Stop all containers for a project.
    func stop(projectId: UUID, timeout: UInt32 = 10) async throws -> ManagedState {
        guard var state = states[projectId] else {
            throw DockerError.commandFailed("Project not found in lifecycle manager")
        }

        state.status = .stopping
        states[projectId] = state

        // Remove TCP port bridges (expose mode)
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

    /// Start a TCP bridge so the app is reachable at 127.0.0.1:hostPort.
    func expose(projectId: UUID) async throws {
        guard let state = states[projectId],
              let svc = state.services.first(where: { $0.hostPort > 0 }) else { return }
        try await VMManager.shared.addTCPBridge(
            localPort: svc.hostPort,
            remoteHost: state.vmIP,
            remotePort: svc.hostPort
        )
        logger.info("Exposed \(state.projectId): 127.0.0.1:\(svc.hostPort) → \(state.vmIP):\(svc.hostPort)")
    }

    /// Remove the TCP bridge (if any).
    func unexpose(projectId: UUID) async {
        guard let state = states[projectId],
              let svc = state.services.first(where: { $0.hostPort > 0 }) else { return }
        await VMManager.shared.removeBridge(localPort: svc.hostPort)
        logger.info("Unexposed \(state.projectId)")
    }

    /// Snapshot all state volumes as tarballs. Returns `volName → tar.gz bytes`.
    /// Returns empty dict if no volumes are declared in the manifest.
    func snapshotState(projectId: UUID) async throws -> [String: Data] {
        guard let state = states[projectId] else { return [:] }
        let volumeNames = Set((state.appManifest.state?.volumes ?? []).map { $0.name })
        guard !volumeNames.isEmpty else { return [:] }

        var result: [String: Data] = [:]
        var snapshotted = Set<String>()

        for svc in state.services {
            for m in svc.mounts where volumeNames.contains(m.source) && !snapshotted.contains(m.source) {
                let hostDir = state.extractDir.appendingPathComponent(m.source)
                result[m.source] = try await createTarball(of: hostDir)
                snapshotted.insert(m.source)
            }
        }
        return result
    }

    /// Returns (vmIP, containerPort, hostPort) for the primary service after start().
    func vmEndpoint(for projectId: UUID) -> (vmIP: String, containerPort: UInt16, hostPort: UInt16)? {
        guard let state = states[projectId],
              let svc = state.services.first(where: { $0.containerPort > 0 }) else { return nil }
        return (vmIP: state.vmIP, containerPort: svc.containerPort, hostPort: svc.hostPort)
    }

    func hostPort(for projectId: UUID) -> UInt16? {
        states[projectId]?.services.first(where: { $0.hostPort > 0 })?.hostPort
    }

    func status(for projectId: UUID) -> RunStatus {
        states[projectId]?.status ?? .stopped
    }

    /// Returns host-side URLs for all declared state volume directories.
    func volumeDirectories(projectId: UUID) -> [URL] {
        guard let state = states[projectId] else { return [] }
        let volumeNames = Set((state.appManifest.state?.volumes ?? []).map { $0.name })
        guard !volumeNames.isEmpty else { return [] }
        var result: [URL] = []
        var seen = Set<String>()
        for svc in state.services {
            for m in svc.mounts where volumeNames.contains(m.source) && !seen.contains(m.source) {
                result.append(state.extractDir.appendingPathComponent(m.source))
                seen.insert(m.source)
            }
        }
        return result
    }

    // MARK: - Private helpers

    private func createTarball(of dir: URL) async throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-czf", "-", "-C", dir.path, "."]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw DockerError.commandFailed("tar snapshot failed (status \(proc.terminationStatus)) for \(dir.lastPathComponent)")
        }
        return data
    }
}
