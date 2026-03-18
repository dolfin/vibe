import Foundation
import Virtualization
import os

private let logger = Logger(subsystem: "ninja.gil.Vibe", category: "VM")

let vmSSHPort: UInt16 = 2222
let vmSSHUser = "root"

/// Manages the Vibe Linux runtime VM via Apple Virtualization.framework.
///
/// Network approach for macOS 26+ (portForwardingRules removed):
/// - VM gets NAT internet access via VZNATNetworkDeviceAttachment
/// - Host↔VM communication uses virtio-vsock (VZVirtioSocketDevice)
/// - SSH bridge: host TCP:2222 ↔ vsock:2222 ↔ VM TCP:22
/// - Container port bridges: same pattern per service
@Observable @MainActor
final class VMManager: NSObject {

    static let shared = VMManager()

    enum State: Equatable {
        case idle
        case booting
        case ready
        case stopping
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Not running"
            case .booting: "Starting runtime…"
            case .ready: "Ready"
            case .stopping: "Stopping…"
            case .failed(let m): "Failed: \(m)"
            }
        }
    }

    var state: State = .idle

    /// Host-side directory shared with VM via virtio-fs (tag: "vibe-shared").
    let sharedDir: URL

    private var vm: VZVirtualMachine?
    private var socketDevice: VZVirtioSocketDevice?
    private var consoleLogFH: FileHandle?
    private var consolePipe: Pipe?
    /// TCP server fds keyed by local port (kept alive to accept new connections).
    /// @ObservationIgnored + nonisolated(unsafe): bypasses @Observable macro so
    /// nonisolated(unsafe) applies to the actual stored property; all accesses
    /// are serialized by portLock.
    @ObservationIgnored nonisolated(unsafe) private var bridgeServers: [UInt16: Int32] = [:]
    /// Established proxy client fds per bridge port. Shutdown on bridge removal to
    /// immediately kill keep-alive connections, not just stop accepting new ones.
    @ObservationIgnored nonisolated(unsafe) private var bridgeClientFds: [UInt16: [Int32]] = [:]
    /// Ports claimed by findAvailablePort but not yet promoted to a full bridge.
    @ObservationIgnored nonisolated(unsafe) private var reservedPorts: Set<UInt16> = []
    private let portLock = NSLock()

    /// Atomically check-and-reserve a port. Returns true if the port was free and
    /// is now reserved; false if it was already claimed by a bridge or reservation.
    /// nonisolated so it can be called from any async context without await.
    nonisolated func claimPort(_ port: UInt16) -> Bool {
        portLock.lock()
        defer { portLock.unlock() }
        let taken = bridgeServers[port] != nil || reservedPorts.contains(port)
        if !taken { reservedPorts.insert(port) }
        return !taken
    }

    nonisolated func releasePort(_ port: UInt16) {
        portLock.lock()
        reservedPorts.remove(port)
        portLock.unlock()
    }

    nonisolated func trackClientFd(_ fd: Int32, port: UInt16) {
        portLock.lock()
        bridgeClientFds[port, default: []].append(fd)
        portLock.unlock()
    }

    private let vmDir: URL

    private override init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        vmDir = appSupport.appendingPathComponent("Vibe/vm", isDirectory: true)
        sharedDir = vmDir.appendingPathComponent("shared", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
    }

    var isReady: Bool { state == .ready }

    /// IP address of the VM on the NAT network (written by vibe-init.sh after DHCP).
    var vmIP: String? {
        let url = sharedDir.appendingPathComponent(".vm-ip")
        guard let data = try? Data(contentsOf: url),
              let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty else { return nil }
        return ip
    }

    private var kernelURL: URL {
        get throws {
            guard let url = Bundle.main.url(forResource: "kernel", withExtension: nil) else {
                throw VMError.bootFailed("VM kernel not found in app bundle — run `make bundle-vm` first")
            }
            return url
        }
    }
    private var initrdURL: URL {
        get throws {
            guard let url = Bundle.main.url(forResource: "initrd", withExtension: nil) else {
                throw VMError.bootFailed("VM initrd not found in app bundle — run `make bundle-vm` first")
            }
            return url
        }
    }
    private var dataDiskURL: URL { vmDir.appendingPathComponent("data.img") }
    private var readyFlagURL: URL { sharedDir.appendingPathComponent(".vibe-ready") }
    var consoleLogURL: URL { vmDir.appendingPathComponent("console.log") }

    /// Create a blank sparse data disk if it doesn't already exist.
    /// Using FileHandle (not dd/subprocess) produces a raw sparse file
    /// that Virtualization.framework accepts on macOS 26.
    private func ensureDataDisk() throws {
        guard !FileManager.default.fileExists(atPath: dataDiskURL.path) else { return }
        let size: UInt64 = 4 * 1024 * 1024 * 1024
        let url = dataDiskURL
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.truncate(atOffset: size)
        logger.info("Created blank data disk at \(url.path)")
    }

    // MARK: - Public API

    /// In-flight boot task. Stored so concurrent callers await the same task
    /// instead of returning early while the VM is still booting.
    private var bootTask: Task<Void, Error>?

    func ensureReady() async throws {
        if isReady { return }
        if let existing = bootTask {
            try await existing.value  // await the in-progress boot — don't return early
            return
        }
        let task = Task { [weak self] in try await self?.boot() ?? () }
        bootTask = task
        defer { bootTask = nil }
        try await task.value
    }

    /// Forward host TCP:localPort → VM TCP remoteHost:remotePort.
    /// Uses the VM's NAT IP directly — same path as SSH, no vsock needed.
    func addTCPBridge(localPort: UInt16, remoteHost: String, remotePort: UInt16) throws {
        // Promote reservation → active bridge (or guard against double-add).
        portLock.lock()
        reservedPorts.remove(localPort)
        guard bridgeServers[localPort] == nil else { portLock.unlock(); return }
        portLock.unlock()

        let serverFd = try makeTCPServer(port: localPort)
        portLock.lock()
        bridgeServers[localPort] = serverFd
        portLock.unlock()

        let localPortCapture = localPort
        Task.detached { [weak self] in
            while true {
                let clientFd = Darwin.accept(serverFd, nil, nil)
                guard clientFd >= 0 else { break }

                // Track this fd so removeBridge can shutdown established connections.
                self?.trackClientFd(clientFd, port: localPortCapture)

                Task.detached {
                    // Retry connectTCP for up to 30s — container app may still be starting.
                    var remoteFd: Int32?
                    for attempt in 1...30 {
                        remoteFd = connectTCP(host: remoteHost, port: remotePort)
                        if remoteFd != nil {
                            logger.info("TCP proxy: connected to \(remoteHost):\(remotePort) on attempt \(attempt)")
                            break
                        }
                        logger.debug("TCP proxy: attempt \(attempt) ECONNREFUSED for \(remoteHost):\(remotePort), retrying…")
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    guard let remoteFd else {
                        logger.warning("TCP proxy: gave up connecting to \(remoteHost):\(remotePort)")
                        Darwin.close(clientFd)
                        return
                    }
                    spliceData(a: clientFd, b: remoteFd, keepAlive: NSObject())
                }
            }
            await self?.cleanupBridge(port: localPortCapture)
        }
        logger.info("TCP bridge: 127.0.0.1:\(localPort) → \(remoteHost):\(remotePort)")
    }

    func removeBridge(localPort: UInt16) {
        portLock.lock()
        reservedPorts.remove(localPort)
        let serverFd = bridgeServers.removeValue(forKey: localPort)
        let clientFds = bridgeClientFds.removeValue(forKey: localPort) ?? []
        portLock.unlock()

        // Close the server socket — stops accepting new connections.
        if let serverFd { Darwin.close(serverFd) }

        // Shutdown established proxy connections so spliceData sees EOF immediately.
        // We use shutdown (not close) so spliceData can still call close() on its side.
        for clientFd in clientFds {
            Darwin.shutdown(clientFd, SHUT_RDWR)
        }
    }

    func clearCaches() async {
        logger.info("Clearing all caches...")
        await stop()
        // Delete the VM data disk (package cache + Docker image cache)
        try? FileManager.default.removeItem(at: dataDiskURL)
        // Delete the .vibeapp package cache
        let pkgCache = StorageManager.packageCacheDir
        try? FileManager.default.removeItem(at: pkgCache)
        StorageManager.ensureDirectories()
        logger.info("All caches cleared. Next boot will re-download packages.")
    }

    func stop() async {
        bootTask?.cancel()
        bootTask = nil
        bridgeServers.values.forEach { Darwin.close($0) }
        bridgeServers.removeAll()
        bridgeClientFds.values.flatMap { $0 }.forEach { Darwin.shutdown($0, SHUT_RDWR) }
        bridgeClientFds.removeAll()
        socketDevice = nil
        try? FileManager.default.removeItem(at: readyFlagURL)
        state = .stopping
        do { try await vm?.stop() } catch {
            logger.warning("VM stop: \(error.localizedDescription)")
        }
        vm = nil
        state = .idle
    }

    // MARK: - Boot

    private func boot() async throws {
        state = .booting
        try? FileManager.default.removeItem(at: readyFlagURL)

        let kURL = try kernelURL
        let iURL = try initrdURL
        try ensureDataDisk()
        let fm = FileManager.default
        logger.info("Boot: kernel=\(kURL.path) exists=\(fm.fileExists(atPath: kURL.path))")
        logger.info("Boot: initrd=\(iURL.path) exists=\(fm.fileExists(atPath: iURL.path))")
        logger.info("Boot: data=\(self.dataDiskURL.path) exists=\(fm.fileExists(atPath: self.dataDiskURL.path))")
        logger.info("Boot: shared=\(self.sharedDir.path)")

        let bootStart = Date()

        // Generate a fresh SSH keypair each boot — the public key goes to the shared dir
        // where vibe-init.sh picks it up for authorized_keys. This guarantees the host's
        // private key always matches what's in the VM, regardless of initrd contents.
        try await generateSSHKeyPair()

        let config = try buildConfig(kernelURL: kURL, initrdURL: iURL)
        let machine = VZVirtualMachine(configuration: config)
        machine.delegate = self
        vm = machine

        try await machine.start()
        logger.info("BENCH vm-start: hypervisor start in \(String(format: "%.2f", -bootStart.timeIntervalSinceNow))s")

        // Grab the vsock device (needed for bridges)
        socketDevice = machine.socketDevices.first as? VZVirtioSocketDevice

        // Wait for vibe-init.sh to touch /vibe-shared/.vibe-ready (~15s normal, ~2min first boot)
        try await waitForReadyFlag(timeout: 300)

        state = .ready
        logger.info("BENCH vm-ready: VM fully ready in \(String(format: "%.2f", -bootStart.timeIntervalSinceNow))s from boot() call")

        // Purge containers and extracted dirs left behind by crashed/force-quit sessions.
        await ContainerRuntimeClient.removeAllVibeContainers()
        cleanupStaleSharedDirs()
    }

    private func generateSSHKeyPair() async throws {
        let keyPath = vmDir.appendingPathComponent("vibe-vm.key")
        let pubPath = vmDir.appendingPathComponent("vibe-vm.key.pub")
        try? FileManager.default.removeItem(at: keyPath)
        try? FileManager.default.removeItem(at: pubPath)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                p.arguments = ["-t", "ed25519", "-f", keyPath.path, "-N", "", "-C", "vibe-vm"]
                p.standardOutput = Pipe()
                let errPipe = Pipe()
                p.standardError = errPipe
                do {
                    try p.run(); p.waitUntilExit()
                    if p.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        cont.resume(throwing: VMError.bootFailed("ssh-keygen: \(msg)"))
                    }
                } catch { cont.resume(throwing: VMError.bootFailed("ssh-keygen: \(error)")) }
            }
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
        // Write pubkey to shared dir — vibe-init.sh will install it into authorized_keys
        let pubKey = try String(contentsOf: pubPath, encoding: .utf8)
        try pubKey.write(to: sharedDir.appendingPathComponent("vibe-vm.pub"), atomically: true, encoding: .utf8)
        logger.info("SSH keypair generated: \(pubKey.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private func buildConfig(kernelURL: URL, initrdURL: URL) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(2, min(4, ProcessInfo.processInfo.processorCount))
        config.memorySize = 2 * 1024 * 1024 * 1024

        // Kernel
        let boot = VZLinuxBootLoader(kernelURL: kernelURL)
        boot.initialRamdiskURL = initrdURL
        boot.commandLine = "console=hvc0 modules=virtio_pci,virtio_blk,virtiofs,vsock,virtio_console"
        config.bootLoader = boot

        // Entropy — required minimum device
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // NAT network — internet access for APK installs inside VM
        let netConfig = VZVirtioNetworkDeviceConfiguration()
        netConfig.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [netConfig]

        // virtio-fs: sharedDir → /vibe-shared inside VM
        let sharedURL = sharedDir
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "vibe-shared")
        fsConfig.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: sharedURL, readOnly: false)
        )
        config.directorySharingDevices = [fsConfig]

        // Persistent data disk — mounted at /var/lib/containerd inside VM.
        // Without this, overlayfs snapshots land on ramfs and pivot_root fails.
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: dataDiskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // vsock — bidirectional host↔VM socket communication
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Console — use a Pipe + config.serialPorts (VZVirtioConsoleDeviceSerialPortConfiguration).
        // Pipes are simpler than PTY and have no terminal-mode blocking issues.
        // VZ writes VM output to the pipe's write end; we drain the read end via readabilityHandler.
        let pipe = Pipe()
        consolePipe = pipe
        let serialPortConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        let devNull = FileHandle(forReadingAtPath: "/dev/null")!
        serialPortConfig.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: devNull,
            fileHandleForWriting: pipe.fileHandleForWriting
        )
        config.serialPorts = [serialPortConfig]

        // Drain pipe → console.log + logger
        FileManager.default.createFile(atPath: consoleLogURL.path, contents: nil)
        let logFH = try? FileHandle(forWritingTo: consoleLogURL)
        consoleLogFH = logFH
        logFH?.write("=== VM console log opened ===\n".data(using: .utf8)!)
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                logger.warning("console pipe EOF — VM may have stopped")
                return
            }
            logFH?.write(data)
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) ?? "<\(data.count) bytes>"
            for line in text.components(separatedBy: .newlines)
                where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                logger.notice("[VM] \(line)")
            }
        }
        logger.info("VM console → Pipe → \(self.consoleLogURL.path)")

        try config.validate()
        logger.info("Config: validated OK — starting VM")
        return config
    }

    private func waitForReadyFlag(timeout: Int = 300) async throws {
        let shared = sharedDir.path
        for second in 0..<timeout {
            if FileManager.default.fileExists(atPath: readyFlagURL.path) {
                logger.info("VM ready after \(second)s")
                return
            }
            if second % 15 == 0 && second > 0 {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: shared)) ?? []
                let vmState = vm.map { "\($0.state)" } ?? "nil"
                logger.info("Waiting for VM (\(second)s / \(timeout)s)… state=\(vmState) shared=\(files)")
                dumpConsoleLog()
            }
            try await Task.sleep(for: .seconds(1))
        }
        dumpConsoleLog()
        throw VMError.timeout("VM did not signal ready within \(timeout)s")
    }

    private func dumpConsoleLog() {
        guard let data = try? Data(contentsOf: consoleLogURL), !data.isEmpty else {
            logger.warning("console.log missing or empty — PTY/VZ write may have failed")
            return
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? "<\(data.count) bytes, unreadable>"
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let tail = lines.suffix(30)
        logger.notice("=== VM console (last \(tail.count)/\(lines.count) lines) ===")
        for line in tail { logger.notice("[VM] \(line)") }
    }

    /// Delete leftover `vibe-<tag>` directories in the VM shared dir.
    /// These are extracted project directories from sessions that ended without cleanup.
    private func cleanupStaleSharedDirs() {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: sharedDir.path) else { return }
        var isDir: ObjCBool = false
        var removed = 0
        for item in contents where item.hasPrefix("vibe-") {
            let url = sharedDir.appendingPathComponent(item)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            try? FileManager.default.removeItem(at: url)
            removed += 1
        }
        if removed > 0 {
            logger.info("Stale shared-dir cleanup: removed \(removed) director(ies)")
        }
    }

    func cleanupBridge(port: UInt16) {
        portLock.lock()
        bridgeServers.removeValue(forKey: port)
        bridgeClientFds.removeValue(forKey: port)
        portLock.unlock()
    }

    // MARK: - TCP server helper

    private func makeTCPServer(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VMError.bootFailed("socket() failed") }
        var reuse: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.bind(fd, sptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw VMError.bootFailed("bind() failed for port \(port): \(errno)")
        }
        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw VMError.bootFailed("listen() failed")
        }
        return fd
    }
}

// MARK: - VZVirtualMachineDelegate

extension VMManager: VZVirtualMachineDelegate {
    nonisolated func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            logger.error("VM crashed: \(error.localizedDescription)")
            self.vm = nil
            self.socketDevice = nil
            self.state = .failed(error.localizedDescription)
        }
    }
    nonisolated func guestDidStop(_ vm: VZVirtualMachine) {
        Task { @MainActor in
            logger.info("VM guest halted")
            self.vm = nil
            self.socketDevice = nil
            self.state = .idle
        }
    }
}

// MARK: - Errors

enum VMError: LocalizedError {
    case bootFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .bootFailed(let m): "VM boot failed: \(m)"
        case .timeout(let m): "VM timeout: \(m)"
        }
    }
}

// MARK: - TCP connect helper (free function — no actor isolation)

/// Open a TCP connection to host:port. Returns the connected fd, or nil on failure.
func connectTCP(host: String, port: UInt16) -> Int32? {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, "\(port)", &hints, &res) == 0, let res else { return nil }
    defer { freeaddrinfo(res) }
    let fd = Darwin.socket(res.pointee.ai_family, res.pointee.ai_socktype, res.pointee.ai_protocol)
    guard fd >= 0 else { return nil }
    guard Darwin.connect(fd, res.pointee.ai_addr, res.pointee.ai_addrlen) == 0 else {
        Darwin.close(fd)
        return nil
    }
    return fd
}

// MARK: - Bidirectional splice (free function — no actor isolation)

/// Forward data between two file descriptors until both sides close.
/// Uses half-close (shutdown SHUT_WR) so a FIN from one side doesn't RST the other.
func spliceData(a: Int32, b: Int32, keepAlive: AnyObject) {
    let lock = NSLock()
    var doneCount = 0

    let finish: (Int32, Int32) -> Void = { src, dst in
        // Half-close: signal EOF toward dst without killing the whole socket.
        Darwin.shutdown(dst, SHUT_WR)
        lock.lock()
        doneCount += 1
        let shouldClose = doneCount == 2
        lock.unlock()
        if shouldClose {
            Darwin.close(a)
            Darwin.close(b)
        }
    }

    let copy: (Int32, Int32) -> Void = { src, dst in
        DispatchQueue.global(qos: .utility).async {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(src, &buf, buf.count)
                guard n > 0 else { break }
                var off = 0
                while off < n {
                    let w = Darwin.write(dst, Array(buf[off..<n]), n - off)
                    guard w > 0 else {
                        finish(src, dst)
                        return
                    }
                    off += w
                }
            }
            finish(src, dst)
        }
    }
    copy(a, b)
    copy(b, a)
}

// MARK: - SSH key helper

func vibeSSHPrivateKeyPath() -> String {
    // Key is generated fresh each boot by VMManager.generateSSHKeyPair() — just return the path.
    let vmDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vibe/vm")
    let dest = vmDir.appendingPathComponent("vibe-vm.key")
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
    return dest.path
}

/// Path to the SSH known_hosts file for the Vibe VM.
/// Uses `libraryDirectory` (no spaces) so SSH's `-o UserKnownHostsFile=` parser doesn't break.
/// Host keys are persisted across VM reboots by vibe-init.sh, so `accept-new` works correctly:
/// the fingerprint is accepted once on first connect and verified on all subsequent connects.
func vibeSSHKnownHostsPath() -> String {
    // libraryDirectory → ~/Library/Containers/<bundle>/Data/Library/ (no spaces in this segment)
    let dir = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vibe/vm")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("known_hosts").path
}
