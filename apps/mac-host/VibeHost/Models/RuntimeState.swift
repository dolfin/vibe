import Foundation
import Observation
import os

private let logger = Logger(subsystem: "ninja.gil.VibeHost", category: "Runtime")

/// Tracks the runtime state of projects (whether they're running in Docker).
@Observable
final class RuntimeState {
    let supervisor = SupervisorClient()

    /// Map of project UUID → supervisor project ID.
    var supervisorIds: [UUID: String] = [:]

    /// Map of project UUID → running status.
    var statuses: [UUID: ProjectRunStatus] = [:]

    /// Map of project UUID → primary host port.
    var hostPorts: [UUID: UInt16] = [:]

    /// Whether the supervisor is reachable.
    var supervisorAvailable = false

    /// Error message to display.
    var lastError: String?

    /// Check if supervisor is available.
    func checkSupervisor() async {
        supervisorAvailable = await supervisor.isAvailable()
    }

    /// Import a package to the supervisor and start it.
    func launchProject(_ project: Project, packagePath: String) async {
        statuses[project.id] = .starting
        lastError = nil

        logger.info("Launching: importing \(packagePath)")
        do {
            // Import the package
            let managed = try await supervisor.importPackage(path: packagePath)
            logger.info("Imported as supervisor project: \(managed.id)")
            supervisorIds[project.id] = managed.id

            // Start it
            logger.info("Starting project \(managed.id)...")
            let started = try await supervisor.startProject(id: managed.id)
            statuses[project.id] = .running
            logger.info("Project started, \(started.services.count) services")

            // Find the primary host port
            if let svc = started.services.first(where: { $0.hostPort > 0 }) {
                hostPorts[project.id] = svc.hostPort
                logger.info("Primary service \(svc.name) on host port \(svc.hostPort)")
            }
        } catch {
            logger.error("Launch failed: \(String(describing: error))")
            statuses[project.id] = .error
            lastError = String(describing: error)
        }
    }

    /// Stop a running project.
    func stopProject(_ project: Project) async {
        guard let supervisorId = supervisorIds[project.id] else { return }
        statuses[project.id] = .stopping

        do {
            _ = try await supervisor.stopProject(id: supervisorId)
            statuses[project.id] = .stopped
            hostPorts[project.id] = nil
        } catch {
            statuses[project.id] = .error
            lastError = error.localizedDescription
        }
    }

    /// Refresh status from supervisor.
    func refreshStatus(_ project: Project) async {
        guard let supervisorId = supervisorIds[project.id] else { return }

        do {
            let managed = try await supervisor.getProject(id: supervisorId)
            switch managed.status {
            case "running": statuses[project.id] = .running
            case "stopped": statuses[project.id] = .stopped
            case "starting": statuses[project.id] = .starting
            case "stopping": statuses[project.id] = .stopping
            default: statuses[project.id] = .error
            }

            if let svc = managed.services.first(where: { $0.hostPort > 0 }) {
                hostPorts[project.id] = svc.hostPort
            }
        } catch {
            // Ignore refresh errors
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
