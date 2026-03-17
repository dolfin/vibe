import Foundation
import os

private let logger = Logger(subsystem: "ninja.gil.VibeHost", category: "Container")

// MARK: - Types

enum DockerError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
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

    // Deduplicates concurrent pulls of the *same* image — if two projects need
    // node:20-alpine simultaneously, only one nerdctl pull runs; the second awaits it.
    // Different images pull concurrently (no global serial queue) so launching several
    // projects at once doesn't cause them to queue behind each other.
    // Timeout is 600s (not 300s) so that even if containerd internally serializes
    // two large concurrent pulls, neither SSH session times out while waiting.
    private nonisolated(unsafe) static var activePullTasks: [String: Task<Void, Error>] = [:]
    private static let pullLock = NSLock()

    static func pullImage(_ image: String) async throws {
        // Fast path: skip if image already exists locally.
        let (_, _, inspectStatus) = try await ssh(["nerdctl", "image", "inspect", image])
        if inspectStatus == 0 {
            logger.info("Image \(image) already present — skipping pull")
            return
        }

        // Deduplicate: if the same image is already being pulled, share the Task.
        let task: Task<Void, Error> = pullLock.withLock {
            if let existing = activePullTasks[image] {
                return existing
            }
            let t = Task<Void, Error> {
                defer {
                    _ = pullLock.withLock { activePullTasks.removeValue(forKey: image) }
                }
                logger.info("Pulling image: \(image)")
                let (_, stderr, status) = try await ssh(["nerdctl", "pull", image], timeout: 600)
                if status != 0 {
                    throw DockerError.commandFailed("nerdctl pull \(image): \(stderr)")
                }
            }
            activePullTasks[image] = t
            return t
        }
        try await task.value
    }

    // MARK: - Containers

    static func runContainer(_ spec: ContainerSpec) async throws -> String {
        try? await removeContainer(name: spec.name)

        var nerdctlArgs = ["nerdctl", "run", "-d", "--name", spec.name]

        for pm in spec.ports {
            nerdctlArgs += ["-p", "\(pm.host):\(pm.container)"]
        }
        for (k, v) in spec.env {
            nerdctlArgs += ["-e", "\(k)=\(v)"]
        }
        for vol in spec.volumes {
            nerdctlArgs += ["-v", "\(vol.hostPath):\(vol.containerPath)"]
        }
        if let wd = spec.workingDir {
            nerdctlArgs += ["-w", wd]
        }
        if let net = spec.network {
            nerdctlArgs += ["--network", net]
        }
        for (k, v) in spec.labels {
            nerdctlArgs += ["--label", "\(k)=\(v)"]
        }
        nerdctlArgs.append(spec.image)
        nerdctlArgs += spec.command

        // nerdctl run -d spawns a background _NERDCTL_INTERNAL_LOGGING daemon that
        // inherits the SSH session's file descriptors, keeping the channel open
        // indefinitely. Fix: background nerdctl with all I/O redirected to a temp
        // file, wait for nerdctl itself to exit (not the daemon), then read the CID.
        let cidFile = "/tmp/.vibe-cid-\(spec.name)"
        let errFile = "/tmp/.vibe-err-\(spec.name)"
        // Shell-quote every argument so metacharacters in command strings (&&, |, etc.)
        // are passed to nerdctl rather than interpreted by the VM's wrapper shell.
        let cmd = nerdctlArgs.map(shellQuote).joined(separator: " ")
        let shellCmd = "\(cmd) >\(cidFile) 2>\(errFile) </dev/null & BGPID=$!; wait $BGPID; STATUS=$?; [ $STATUS -eq 0 ] && cat \(cidFile) || (cat \(errFile) >&2; exit $STATUS)"

        // Pass shellCmd as a single arg — sshd wraps it in `sh -c` automatically.
        // Do NOT use ssh(["sh", "-c", shellCmd]): that creates a double sh -c invocation
        // where nerdctl receives no arguments and prints help.
        logger.info("Starting container: \(spec.name)")
        let (stdout, stderr, status) = try await ssh([shellCmd])
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

    // MARK: - Port resolution

    static func findAvailablePort(preferred: UInt16) async -> UInt16 {
        // Sandboxed apps can't bind privileged ports (< 1024), so map to 8000+.
        let base = max(preferred, 8000)
        let vmUsed = await vmUsedPorts()
        // Capture the VMManager reference on the main actor once; claimPort() is
        // nonisolated so it can be called directly without further actor hops.
        let vm = await MainActor.run { VMManager.shared }
        // claimPort() atomically checks bridge/reservation state and reserves the port,
        // preventing races between concurrent project launches.
        for port in base..<(base + 100) {
            if vmUsed.contains(port) { continue }
            if isHostPortAvailable(port) && vm.claimPort(port) { return port }
        }
        let p = ephemeralPort()
        if p > 0 { _ = vm.claimPort(p) }
        return p
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

        // Copy private key to NSTemporaryDirectory — App Sandbox may block child processes
        // (like /usr/bin/ssh) from reading files inside the container directory.
        let fm = FileManager.default
        let tmpKey = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-\(UUID().uuidString).key")
        do {
            try fm.copyItem(atPath: keyPath, toPath: tmpKey.path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpKey.path)
        } catch {
            logger.error("Key copy to tmp FAILED: \(error) — using original path")
        }
        defer { try? fm.removeItem(at: tmpKey) }

        let effectiveKeyPath = fm.fileExists(atPath: tmpKey.path) ? tmpKey.path : keyPath
        let sshArgs = [
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

    // MARK: - Shell helpers

    /// POSIX single-quote a string so metacharacters are not interpreted by the
    /// VM's wrapper shell. Safe characters are passed through unquoted.
    private static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.:/=@,"))
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
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

                    // Drain stdout and stderr on separate threads WHILE the process runs.
                    // Without this, a subprocess that writes > ~64 KB (macOS pipe buffer)
                    // blocks on its write() call, process.waitUntilExit() never returns,
                    // and we deadlock. nerdctl pull easily exceeds this with progress output.
                    var stdoutData = Data()
                    var stderrData = Data()
                    let drainGroup = DispatchGroup()

                    drainGroup.enter()
                    DispatchQueue.global().async {
                        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        drainGroup.leave()
                    }
                    drainGroup.enter()
                    DispatchQueue.global().async {
                        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        drainGroup.leave()
                    }

                    process.waitUntilExit()
                    timer.cancel()
                    drainGroup.wait()  // ensure both pipes are fully read

                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
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
