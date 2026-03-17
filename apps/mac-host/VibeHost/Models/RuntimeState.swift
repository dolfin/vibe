import Foundation
import Observation
import os

private let logger = Logger(subsystem: "ninja.gil.VibeHost", category: "Runtime")

/// Tracks the runtime state of projects (whether they're running in the Vibe VM).
@Observable
final class RuntimeState {
    /// One lifecycle manager per project so launches run concurrently.
    private var lifecycles: [UUID: ProjectLifecycleManager] = [:]

    /// Map of project UUID → running status.
    var statuses: [UUID: ProjectRunStatus] = [:]

    /// Map of project UUID → primary host port (only set when the project is exposed).
    var hostPorts: [UUID: UInt16] = [:]

    /// Map of project UUID → VM endpoint (vmIP, containerPort, hostPort). Set after start().
    var vmEndpoints: [UUID: (vmIP: String, containerPort: UInt16, hostPort: UInt16)] = [:]

    /// Map of project UUID → in-progress status message (e.g. "Pulling images…").
    var statusMessages: [UUID: String] = [:]

    /// Error message to display (most recent launch failure).
    var lastError: String?

    private func lifecycle(for project: Project) -> ProjectLifecycleManager {
        if let mgr = lifecycles[project.id] { return mgr }
        let mgr = ProjectLifecycleManager()
        lifecycles[project.id] = mgr
        return mgr
    }

    /// Check if the Vibe runtime VM is already running (does NOT start it).
    @MainActor
    func checkRuntime() async {
    }

    /// Launch a project — boot VM if needed, extract, start containers.
    func launchProject(_ project: Project) async {
        statuses[project.id] = .starting
        lastError = nil
        statusMessages[project.id] = nil

        logger.info("Launching project: \(project.appName)")
        do {
            try await VMManager.shared.ensureReady()

            let mgr = lifecycle(for: project)
            _ = try await mgr.prepare(project: project)

            statusMessages[project.id] = "Pulling images — first run may take a few minutes…"
            _ = try await mgr.start(projectId: project.id)
            statusMessages[project.id] = nil
            statuses[project.id] = .running

            if let ep = await mgr.vmEndpoint(for: project.id) {
                vmEndpoints[project.id] = ep
                logger.info("VM endpoint: \(ep.vmIP):\(ep.containerPort) (host port \(ep.hostPort) reserved)")
            }
        } catch {
            logger.error("Launch failed: \(String(describing: error))")
            statuses[project.id] = .error
            statusMessages[project.id] = nil
            lastError = String(describing: error)
        }
    }

    /// Stop a running project.
    func stopProject(_ project: Project) async {
        statuses[project.id] = .stopping

        // Tear down the TCP bridge before stopping containers.
        await unexposeProject(project)

        do {
            _ = try await lifecycle(for: project).stop(projectId: project.id)
            statuses[project.id] = .stopped
            hostPorts[project.id] = nil
            vmEndpoints[project.id] = nil
            lifecycles[project.id] = nil
        } catch {
            statuses[project.id] = .error
            lastError = String(describing: error)
        }
    }

    /// Create a TCP bridge so the app is accessible at 127.0.0.1:hostPort.
    func exposeProject(_ project: Project) async {
        let mgr = lifecycle(for: project)
        do {
            try await mgr.expose(projectId: project.id)
            if let ep = await mgr.vmEndpoint(for: project.id) {
                hostPorts[project.id] = ep.hostPort
            }
        } catch {
            logger.error("Expose failed: \(String(describing: error))")
            lastError = String(describing: error)
        }
    }

    /// Remove the TCP bridge.
    func unexposeProject(_ project: Project) async {
        await lifecycle(for: project).unexpose(projectId: project.id)
        hostPorts[project.id] = nil
    }

    func isExposed(_ project: Project) -> Bool {
        hostPorts[project.id] != nil
    }

    func exposedPort(for project: Project) -> UInt16? {
        hostPorts[project.id]
    }

    func vmEndpoint(for project: Project) -> (vmIP: String, containerPort: UInt16, hostPort: UInt16)? {
        vmEndpoints[project.id]
    }

    func status(for project: Project) -> ProjectRunStatus {
        statuses[project.id] ?? .stopped
    }

    func hostPort(for project: Project) -> UInt16? {
        hostPorts[project.id]
    }

    func statusMessage(for project: Project) -> String? {
        statusMessages[project.id]
    }

    /// Snapshot all declared state volumes for a running project.
    func snapshotState(_ project: Project) async throws -> [String: Data] {
        try await lifecycle(for: project).snapshotState(projectId: project.id)
    }

    /// Stop all currently running projects (used when the document is replaced
    /// by a version restore so the old containers don't keep running).
    func stopAllProjects() async {
        let snapshot = lifecycles
        for (id, mgr) in snapshot {
            statuses[id] = .stopping
            await mgr.unexpose(projectId: id)
            _ = try? await mgr.stop(projectId: id)
            statuses[id] = .stopped
            hostPorts[id] = nil
            vmEndpoints[id] = nil
        }
        lifecycles.removeAll()
    }

    /// Returns host-side URLs for all declared state volume directories.
    func volumeDirectories(for project: Project) async -> [URL] {
        await lifecycle(for: project).volumeDirectories(projectId: project.id)
    }
}

enum ProjectRunStatus {
    case stopped
    case starting
    case running
    case stopping
    case error
}
