import Foundation
import os

private let logger = Logger(subsystem: "ninja.gil.VibeHost", category: "Container")

// MARK: - Shared types (previously in DockerClient.swift)

enum DockerError: LocalizedError {
    case notFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: "Vibe Runtime not available — is the VM running?"
        case .commandFailed(let msg): "Container error: \(msg)"
        }
    }
}

struct ContainerSpec {
    let name: String
    let image: String
    let command: [String]
    let env: [String: String]
    let ports: [DockerPortMapping]
    let volumes: [DockerVolumeMount]
    let workingDir: String?
    let network: String?
    let labels: [String: String]
}

struct DockerPortMapping {
    let host: UInt16
    let container: UInt16
}

struct DockerVolumeMount {
    let hostPath: String
    let containerPath: String
}

// MARK: - ContainerRuntimeClient

/// Container runtime client — runs nerdctl inside the Vibe Linux VM via SSH.
enum ContainerRuntimeClient {

    // MARK: - Health check

    static func check() async throws {
        let (_, stderr, status) = try await ssh(["nerdctl", "info"])
        if status != 0 {
            throw DockerError.commandFailed("nerdctl info: \(stderr)")
        }
    }

    // MARK: - Images

    static func pullImage(_ image: String) async throws {
        // Skip pull if image already exists locally — avoids hanging registry check
        let (_, _, inspectStatus) = try await ssh(["nerdctl", "image", "inspect", image])
        if inspectStatus == 0 {
            logger.info("Image \(image) already present — skipping pull")
            return
        }
        logger.info("Pulling image: \(image)")
        let (_, stderr, status) = try await ssh(["nerdctl", "pull", image], timeout: 300)
        if status != 0 {
            throw DockerError.commandFailed("nerdctl pull \(image): \(stderr)")
        }
    }

    // MARK: - Containers

    static func runContainer(_ spec: ContainerSpec) async throws -> String {
        try? await removeContainer(name: spec.name)

        var args = ["nerdctl", "run", "-d", "--name", spec.name]

        for pm in spec.ports {
            args += ["-p", "127.0.0.1:\(pm.host):\(pm.container)"]
        }
        for (k, v) in spec.env {
            args += ["-e", "\(k)=\(v)"]
        }
        for vol in spec.volumes {
            args += ["-v", "\(vol.hostPath):\(vol.containerPath)"]
        }
        if let wd = spec.workingDir {
            args += ["-w", wd]
        }
        if let net = spec.network {
            args += ["--network", net]
        }
        for (k, v) in spec.labels {
            args += ["--label", "\(k)=\(v)"]
        }
        args.append(spec.image)
        args += spec.command

        logger.info("Starting container: \(spec.name)")
        let (stdout, stderr, status) = try await ssh(args)
        if status != 0 {
            throw DockerError.commandFailed("nerdctl run \(spec.name): \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stopContainer(name: String, timeout: UInt32 = 10) async throws {
        let (_, stderr, status) = try await ssh(["nerdctl", "stop", "-t", "\(timeout)", name])
        if status != 0 {
            throw DockerError.commandFailed("nerdctl stop \(name): \(stderr)")
        }
    }

    static func removeContainer(name: String) async throws {
        let (_, stderr, status) = try await ssh(["nerdctl", "rm", "-f", name])
        if status != 0 && !stderr.contains("No such container") {
            throw DockerError.commandFailed("nerdctl rm \(name): \(stderr)")
        }
    }

    static func isRunning(name: String) async -> Bool {
        guard let (stdout, _, status) = try? await ssh([
            "nerdctl", "inspect", "--format", "{{.State.Running}}", name
        ]) else { return false }
        return status == 0 && stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    // MARK: - Networks

    static func createNetwork(_ name: String) async throws {
        let (_, stderr, status) = try await ssh(["nerdctl", "network", "create", name])
        if status != 0 && !stderr.contains("already exists") {
            throw DockerError.commandFailed("nerdctl network create \(name): \(stderr)")
        }
    }

    static func removeNetwork(_ name: String) async throws {
        _ = try? await ssh(["nerdctl", "network", "rm", name])
    }

    // MARK: - Port resolution

    static func findAvailablePort(preferred: UInt16) async -> UInt16 {
        let used = await vmUsedPorts()
        for port in preferred..<(preferred + 100) {
            if used.contains(port) { continue }
            if isHostPortAvailable(port) { return port }
        }
        return ephemeralPort()
    }

    private static func vmUsedPorts() async -> Set<UInt16> {
        var ports = Set<UInt16>()
        guard let (stdout, _, _) = try? await ssh(["nerdctl", "ps", "--format", "{{.Ports}}"]) else {
            return ports
        }
        for segment in stdout.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let s = segment.trimmingCharacters(in: .whitespaces)
            if let arrowRange = s.range(of: "->") {
                let beforeArrow = s[s.startIndex..<arrowRange.lowerBound]
                if let colonIdx = beforeArrow.lastIndex(of: ":"),
                   let port = UInt16(beforeArrow[beforeArrow.index(after: colonIdx)...]) {
                    ports.insert(port)
                }
            }
        }
        return ports
    }

    // MARK: - SSH runner

    /// Execute a command inside the VM via SSH.
    /// Connects directly to the VM's NAT IP on port 22 (no vsock bridge needed).
    /// Retries on connection-level failures (sshd may still be starting up).
    static func ssh(_ args: [String], timeout: TimeInterval = 60) async throws -> (stdout: String, stderr: String, status: Int32) {
        let keyPath = vibeSSHPrivateKeyPath()
        let vmHost = await VMManager.shared.vmIP ?? "127.0.0.1"
        logger.info("SSH → \(vmSSHUser)@\(vmHost):22 key exists=\(FileManager.default.fileExists(atPath: keyPath))")

        // Copy private key to NSTemporaryDirectory — App Sandbox may block child processes
        // (like /usr/bin/ssh) from reading files inside the container directory.
        let fm = FileManager.default
        let tmpKey = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-\(UUID().uuidString).key")
        do {
            try fm.copyItem(atPath: keyPath, toPath: tmpKey.path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpKey.path)
            logger.info("Copied key to tmp: \(tmpKey.path) exists=\(fm.fileExists(atPath: tmpKey.path))")
        } catch {
            logger.error("Key copy to tmp FAILED: \(error) — using original path")
        }
        defer { try? fm.removeItem(at: tmpKey) }

        let effectiveKeyPath = fm.fileExists(atPath: tmpKey.path) ? tmpKey.path : keyPath
        let sshArgs = [
            "-vvv",
            "-p", "22",
            "-i", effectiveKeyPath,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=5",
            "\(vmSSHUser)@\(vmHost)"
        ] + args

        var lastResult: (stdout: String, stderr: String, status: Int32) = ("", "", -1)
        for attempt in 1...5 {
            lastResult = try await runProcess("/usr/bin/ssh", args: sshArgs, timeout: timeout)
            // Log verbose SSH output to help diagnose auth failures
            if !lastResult.stderr.isEmpty {
                logger.info("SSH attempt \(attempt) stderr: \(lastResult.stderr)")
            }
            // On auth failure, dump sshd-side debug log from the shared dir
            if lastResult.stderr.contains("Permission denied") {
                let sshdLog = await VMManager.shared.sharedDir.appendingPathComponent("sshd-debug.log")
                if let logData = try? Data(contentsOf: sshdLog),
                   let logText = String(data: logData, encoding: .utf8) {
                    // Show last 60 lines to avoid spamming
                    let lines = logText.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    let tail = lines.suffix(60).joined(separator: "\n")
                    logger.info("sshd-debug.log (last 60 lines):\n\(tail)")
                } else {
                    logger.warning("sshd-debug.log not readable or absent")
                }
            }
            // Exit code 255 = SSH transport error (connection reset, refused, etc.)
            if lastResult.status != 255 { return lastResult }
            let isConnErr = lastResult.stderr.contains("Connection reset")
                || lastResult.stderr.contains("Connection refused")
                || lastResult.stderr.contains("kex_exchange_identification")
            guard isConnErr && attempt < 5 else { return lastResult }
            logger.warning("SSH attempt \(attempt) failed (transport), retrying in 2s…")
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return lastResult
    }

    // MARK: - Port helpers

    private static func isHostPortAvailable(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        let result: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func ephemeralPort() -> UInt16 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return 0 }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 0 }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &len)
            }
        }
        return UInt16(bigEndian: bound.sin_port)
    }

    // MARK: - Process runner

    private static func runProcess(
        _ executable: String, args: [String], timeout: TimeInterval = 60
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                var timedOut = false
                timer.setEventHandler {
                    timedOut = true
                    process.terminate()
                    timer.cancel()
                }

                do {
                    try process.run()
                    timer.resume()
                    process.waitUntilExit()
                    timer.cancel()
                    let stdout = String(
                        data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    let stderr = String(
                        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    if timedOut {
                        continuation.resume(returning: (stdout, stderr, 255))
                    } else {
                        continuation.resume(returning: (stdout, stderr, process.terminationStatus))
                    }
                } catch {
                    timer.cancel()
                    continuation.resume(throwing: DockerError.commandFailed(error.localizedDescription))
                }
            }
        }
    }
}
