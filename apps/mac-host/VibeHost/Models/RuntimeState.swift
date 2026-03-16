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

    /// Map of project UUID → primary host port.
    var hostPorts: [UUID: UInt16] = [:]

    /// Map of project UUID → in-progress status message (e.g. "Pulling images…").
    var statusMessages: [UUID: String] = [:]

    /// Whether the Vibe VM runtime is available.
    var vmReady = false

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
        vmReady = VMManager.shared.isReady
    }

    /// Launch a project — boot VM if needed, extract, start containers.
    func launchProject(_ project: Project) async {
        statuses[project.id] = .starting
        lastError = nil
        statusMessages[project.id] = nil

        logger.info("Launching project: \(project.appName)")
        do {
            try await VMManager.shared.ensureReady()
            vmReady = await VMManager.shared.isReady

            let mgr = lifecycle(for: project)
            _ = try await mgr.prepare(project: project)

            statusMessages[project.id] = "Pulling images — first run may take a few minutes…"
            let state = try await mgr.start(projectId: project.id)
            statusMessages[project.id] = nil
            statuses[project.id] = .running

            if let port = state.services.first(where: { $0.hostPort > 0 })?.hostPort {
                hostPorts[project.id] = port
                logger.info("Primary service on host port \(port)")
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

        do {
            _ = try await lifecycle(for: project).stop(projectId: project.id)
            statuses[project.id] = .stopped
            hostPorts[project.id] = nil
            lifecycles[project.id] = nil
        } catch {
            statuses[project.id] = .error
            lastError = String(describing: error)
        }
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
}

enum ProjectRunStatus {
    case stopped
    case starting
    case running
    case stopping
    case error
}
