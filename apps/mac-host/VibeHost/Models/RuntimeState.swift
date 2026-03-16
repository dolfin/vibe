import Foundation
import Observation
import os

private let logger = Logger(subsystem: "ninja.gil.VibeHost", category: "Runtime")

/// Tracks the runtime state of projects (whether they're running in the Vibe VM).
@Observable
final class RuntimeState {
    let lifecycle = ProjectLifecycleManager()

    /// Map of project UUID → running status.
    var statuses: [UUID: ProjectRunStatus] = [:]

    /// Map of project UUID → primary host port.
    var hostPorts: [UUID: UInt16] = [:]

    /// Whether the Vibe VM runtime is available.
    var vmReady = false

    /// Error message to display.
    var lastError: String?

    /// Check if the Vibe runtime VM is already running (does NOT start it).
    @MainActor
    func checkRuntime() async {
        vmReady = VMManager.shared.isReady
    }

    /// Launch a project — boot VM if needed, extract, start containers.
    func launchProject(_ project: Project) async {
        statuses[project.id] = .starting
        lastError = nil

        logger.info("Launching project: \(project.appName)")
        do {
            try await VMManager.shared.ensureReady()
            vmReady = await VMManager.shared.isReady
            _ = try await lifecycle.prepare(project: project)
            let state = try await lifecycle.start(projectId: project.id)
            statuses[project.id] = .running

            if let port = state.services.first(where: { $0.hostPort > 0 })?.hostPort {
                hostPorts[project.id] = port
                logger.info("Primary service on host port \(port)")
            }
        } catch {
            logger.error("Launch failed: \(String(describing: error))")
            statuses[project.id] = .error
            lastError = String(describing: error)
        }
    }

    /// Stop a running project.
    func stopProject(_ project: Project) async {
        statuses[project.id] = .stopping

        do {
            _ = try await lifecycle.stop(projectId: project.id)
            statuses[project.id] = .stopped
            hostPorts[project.id] = nil
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
}

enum ProjectRunStatus {
    case stopped
    case starting
    case running
    case stopping
    case error
}
