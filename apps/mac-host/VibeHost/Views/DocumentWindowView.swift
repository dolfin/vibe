import SwiftUI
import AppKit
import os

private let logger = Logger(subsystem: "app.dotvibe.Vibe", category: "DocumentWindow")

/// Per-document window: WebKit fills the window, auto-launches on open.
/// An (i) toolbar button opens a sheet with all technical details.
struct DocumentWindowView: View {
    @Binding var document: VibeAppDocument
    let fileURL: URL?
    @Environment(VaultStore.self) private var vaultStore
    @Environment(ProjectStore.self) private var projectStore
    @AppStorage("vibeHeaderVisible") private var headerVisible = true
    @State private var runtime = RuntimeState()
    @State private var isWebLoading = true
    @State private var webError: String?
    @State private var currentURL: URL?
    @State private var schemeHandler: VibeSchemeHandler?
    @State private var webViewID = UUID()
    @State private var pollingTask: Task<Void, Never>?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var navControl = WebViewNavControl()
    @State private var infoWindowController: NSWindowController?

    private enum ActiveSheet: Identifiable {
        case secrets, trustWarning, trustPublisher
        var id: String {
            switch self {
            case .secrets: "secrets"
            case .trustWarning: "trustWarning"
            case .trustPublisher: "trustPublisher"
            }
        }
    }
    @State private var activeSheet: ActiveSheet?

    private var project: Project { document.project }
    private var status: ProjectRunStatus { runtime.status(for: project) }

    var body: some View {
        content
            .background(WindowConfigurator(headerVisible: headerVisible))
            .navigationTitle(project.appName)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    let ui = project.capabilities.browserUI
                    if headerVisible {
                        if ui.showBackButton {
                            Button {
                                navControl.goBack?()
                            } label: {
                                Image(systemName: "chevron.backward")
                            }
                            .disabled(!canGoBack)
                            .help("Back")
                            .accessibilityLabel("Go back")
                        }
                        if ui.showForwardButton {
                            Button {
                                navControl.goForward?()
                            } label: {
                                Image(systemName: "chevron.forward")
                            }
                            .disabled(!canGoForward)
                            .help("Forward")
                            .accessibilityLabel("Go forward")
                        }
                        if ui.showReloadButton {
                            Button {
                                if isWebLoading { navControl.stopLoading?() } else { navControl.reload?() }
                            } label: {
                                Image(systemName: isWebLoading ? "xmark" : "arrow.clockwise")
                            }
                            .help(isWebLoading ? "Stop" : "Reload")
                            .accessibilityLabel(isWebLoading ? "Stop loading" : "Reload page")
                        }
                        if ui.showHomeButton {
                            Button {
                                navControl.goHome?()
                            } label: {
                                Image(systemName: "house")
                            }
                            .help("Home")
                            .accessibilityLabel("Go to home page")
                        }
                    }
                    Button {
                        openInfoWindow()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .help("Get Info")
                    .accessibilityLabel("App information")
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .secrets:
                    SecretsEntryView(project: project, mode: .launch) { secrets in
                        Task { await doLaunch(secrets: secrets) }
                    }
                case .trustWarning:
                    TrustWarningSheet(
                        trustStatus: project.trustStatus,
                        appName: project.appName,
                        onProceed: {
                            Task { await proceedWithLaunch() }
                        }
                    )
                case .trustPublisher:
                    TrustPublisherSheet(
                        project: project,
                        onProceed: {
                            Task { await proceedWithLaunch() }
                        }
                    )
                }
            }
            .task {
                projectStore.registerOpened(project, fileURL: fileURL)
                guard !project.packageCachePath.isEmpty else { return }
                await runtime.checkRuntime()
                await launchCurrentProject()
            }
            .onReceive(NotificationCenter.default.publisher(for: .vibeNavigateHome)) { _ in
                guard !project.packageCachePath.isEmpty else { return }
                navControl.goHome?()
            }
            // When macOS restores a previous version (File > Revert To > Browse All Versions),
            // VibeAppDocument.init(configuration:) is called with the old file, producing a
            // new project with a fresh UUID. Detect this and restart the containers so the
            // app reflects the restored state instead of continuing to run (and auto-save)
            // the newer state on top of the restore.
            .onChange(of: project.id) { _, _ in
                Task {
                    if let task = pollingTask {
                        task.cancel()
                        await task.value
                    }
                    pollingTask = nil
                    schemeHandler = nil
                    await runtime.stopAllProjects()
                    await launchCurrentProject()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vibeExposeChanged)) { notif in
                guard let projectId = notif.userInfo?["projectId"] as? UUID,
                      projectId == project.id,
                      let exposed = notif.userInfo?["exposed"] as? Bool else { return }
                if exposed {
                    schemeHandler = nil
                } else if let ep = runtime.vmEndpoint(for: project) {
                    schemeHandler = VibeSchemeHandler(vmIP: ep.vmIP, port: ep.hostPort)
                }
                webViewID = UUID()
            }
            .onDisappear {
                infoWindowController?.window?.close()
                let task = pollingTask
                pollingTask = nil
                task?.cancel()
                let p = project; let rt = runtime
                Task {
                    await task?.value
                    await rt.stopProject(p)
                }
            }
            .frame(minWidth: 800, minHeight: 600)
            .focusedSceneValue(\.vibeDocumentContext, VibeDocumentContext(
                project: project,
                fileURL: fileURL,
                revert: { await revertAction() },
                showInfo: { openInfoWindow() }
            ))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if runtime.isExposed(project), let port = runtime.exposedPort(for: project),
           let appURL = URL(string: "http://127.0.0.1:\(port)") {
            webContent(url: appURL, schemeHandler: nil)
        } else if let handler = schemeHandler {
            webContent(url: URL(string: "vibe-app://app/")!, schemeHandler: handler)
        } else {
            launchingOverlay
        }
    }

    private func webContent(url: URL, schemeHandler: VibeSchemeHandler?) -> some View {
        ZStack {
            WebView(
                url: url,
                schemeHandler: schemeHandler,
                isLoading: $isWebLoading,
                loadError: $webError,
                currentURL: $currentURL,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                navControl: navControl
            )
            .id(webViewID)
            if isWebLoading && webError == nil {
                ProgressView("Connecting to \(project.appName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background.opacity(0.92))
            }
            if let error = webError {
                webErrorOverlay(error)
            }
        }
    }

    // MARK: - Info Window

    private func openInfoWindow() {
        if let wc = infoWindowController, let win = wc.window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let infoView = ProjectInfoView(
            project: project,
            runtime: runtime,
            fileURL: fileURL,
            rawPackageSize: document.rawPackageData.count
        )
        .environment(projectStore)
        .environment(vaultStore)

        let hosting = NSHostingController(rootView: infoView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(project.appName) Info"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setFrameAutosaveName("VibeInfo-\(project.id.uuidString)")
        window.isReleasedWhenClosed = false
        window.center()
        let wc = NSWindowController(window: window)
        wc.showWindow(nil)
        infoWindowController = wc
    }

    // MARK: - Launch

    private func launchCurrentProject() async {
        guard !project.packageCachePath.isEmpty else { return }

        // Route to the appropriate trust UI before launching.
        switch project.trustStatus {
        case .tampered, .unsigned:
            activeSheet = .trustWarning
            return
        case .newPublisher:
            activeSheet = .trustPublisher
            return
        case .verified, .trustedByUser:
            break
        }

        await proceedWithLaunch()
    }

    private func proceedWithLaunch() async {
        activeSheet = nil
        let missing = project.capabilities.requiredSecrets.filter { envVar in
            vaultStore.binding(packageId: project.packageCachePath, envVar: envVar) == nil &&
            SecretsManager.load(packageId: project.packageCachePath, name: envVar) == nil
        }
        if missing.isEmpty {
            let secrets = resolveSecrets()
            await doLaunch(secrets: secrets)
        } else {
            activeSheet = .secrets
        }
    }

    /// Builds the secrets dict by checking vault bindings first, then legacy keychain.
    private func resolveSecrets() -> [String: String] {
        var secrets: [String: String] = [:]
        for name in project.capabilities.declaredSecrets {
            if let entry = vaultStore.binding(packageId: project.packageCachePath, envVar: name),
               let value = vaultStore.loadValue(for: entry) {
                secrets[name] = value
            } else if let value = SecretsManager.load(packageId: project.packageCachePath, name: name) {
                secrets[name] = value
            }
        }
        return secrets
    }

    private func doLaunch(secrets: [String: String] = [:]) async {
        await runtime.launchProject(project, secrets: secrets)
        if let ep = runtime.vmEndpoint(for: project) {
            schemeHandler = VibeSchemeHandler(vmIP: ep.vmIP, port: ep.hostPort)
            startPortReadyPolling(vmIP: ep.vmIP, hostPort: ep.hostPort)
        }
        startVolumePolling()
    }

    private func startPortReadyPolling(vmIP: String, hostPort: UInt16) {
        Task {
            for _ in 0..<180 {  // up to 6 min (180 × 2s)
                try? await Task.sleep(for: .seconds(2))
                guard status == .running else { return }
                guard webError != nil else { return }  // already connected
                if await tcpPortOpen(host: vmIP, port: hostPort) {
                    webError = nil
                    webViewID = UUID()
                    return
                }
            }
        }
    }

    // MARK: - Volume polling

    private func startVolumePolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            var lastModDates: [URL: Date] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard status == .running, !project.packageCachePath.isEmpty else { continue }

                let volDirs = await runtime.volumeDirectories(for: project)
                guard !volDirs.isEmpty else { continue }

                var changed = false
                for dir in volDirs {
                    let modDate = latestModDate(in: dir)
                    if let mod = modDate {
                        if let last = lastModDates[dir] {
                            if mod > last { changed = true }
                        }
                        lastModDates[dir] = mod
                    }
                }

                guard changed else { continue }

                do {
                    let entries = try await runtime.snapshotState(project)
                    guard !entries.isEmpty else { continue }

                    StorageManager.saveState(entries, for: project.packageCachePath)

                    let cacheURL = StorageManager.packageCacheDir
                        .appendingPathComponent(project.packageCachePath)
                        .appendingPathComponent("package.vibeapp")
                    let baseData = try Data(contentsOf: cacheURL)
                    let newData = try PackageExtractor.rebuildWithState(baseData: baseData, stateEntries: entries)

                    await MainActor.run {
                        document.rawPackageData = newData
                    }
                    logger.info("Auto-snapshot: marked document as Edited (\(entries.count) volume(s))")
                } catch {
                    logger.warning("Auto-snapshot failed: \(String(describing: error))")
                }
            }
        }
    }

    private func latestModDate(in dir: URL) -> Date? {
        // Include the directory's own mtime as the baseline. A directory's mtime
        // changes whenever files are added or removed — so an empty-but-existing
        // directory still produces a stable (non-nil) value that will advance on
        // the first write, letting the poller detect the initial data creation.
        var latest = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return latest }
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate {
                if latest == nil || date > latest! { latest = date }
            }
        }
        return latest
    }

    // MARK: - Revert

    private func revertAction() async {
        guard !project.packageCachePath.isEmpty else { return }

        // Step 1: Cancel polling and WAIT for the task to fully exit.
        // Swift cooperative cancellation only takes effect at suspension points.
        // The snapshot loop runs tar + StorageManager.saveState() synchronously,
        // so simply calling cancel() doesn't prevent a final stateDir write from
        // racing with our deletion below. Awaiting the task value ensures no
        // concurrent writer remains before we touch the state directory.
        if let task = pollingTask {
            task.cancel()
            await task.value   // blocks until the task's loop exits
        }
        pollingTask = nil

        // Step 2: Show launching overlay and stop containers.
        // Containers must be stopped before we delete stateDir so no in-flight
        // container write can restore dirty data after the deletion.
        schemeHandler = nil
        await runtime.stopProject(project)

        // Step 3: Delete saved state — now safe, no writer can race.
        let stateDir = StorageManager.stateDir(for: project.packageCachePath)
        do {
            try FileManager.default.removeItem(at: stateDir)
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                logger.warning("Failed to remove state directory: \(error)")
            }
        }

        // Step 4: Write the clean (state-free) cached package back to disk.
        let cacheURL = StorageManager.packageCacheDir
            .appendingPathComponent(project.packageCachePath)
            .appendingPathComponent("package.vibeapp")
        guard let cleanData = try? Data(contentsOf: cacheURL) else { return }
        document.rawPackageData = cleanData
        await NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)

        // Step 5: Relaunch. prepare() will find no savedState and no initialState,
        // so the volume directory starts completely empty.
        await launchCurrentProject()
        logger.info("Reverted to original state and reloaded")
    }

    // MARK: - Overlays

    private var launchingOverlay: some View {
        VStack(spacing: 20) {
            AppIconView(project: project)
                .frame(width: 80, height: 80)

            Text(project.appName)
                .font(.title.weight(.semibold))

            if let publisher = project.publisher {
                Text(publisher)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 8)

            switch status {
            case .starting:
                VStack(spacing: 10) {
                    ProgressView()
                    Text(runtime.statusMessage(for: project) ?? "Starting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

            case .error:
                VStack(spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.red)
                    if let err = runtime.lastError {
                        Text(err)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }
                    Button("Retry") {
                        Task { await launchCurrentProject() }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }

            case .stopping:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Stopping…").foregroundStyle(.secondary)
                }

            default:
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func webErrorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Unable to Connect")
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("The app may still be starting up.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Retry") {
                webError = nil
                isWebLoading = true
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .padding()
    }

}

// MARK: - Info Window

private struct ProjectInfoView: View {
    let project: Project
    let runtime: RuntimeState
    let fileURL: URL?
    let rawPackageSize: Int
    @Environment(ProjectStore.self) private var projectStore

    @State private var showManageSecrets = false
    @State private var isFileLocked = false

    private var currentProject: Project {
        projectStore.projects.first(where: { $0.packageCachePath == project.packageCachePath }) ?? project
    }

    private var lockableURL: URL? {
        if let path = currentProject.originalPackagePath,
           !path.contains(Bundle.main.bundlePath),
           !path.hasPrefix(StorageManager.packageCacheDir.path) {
            return URL(fileURLWithPath: path)
        }
        guard let url = fileURL,
              !url.path.hasPrefix(StorageManager.packageCacheDir.path) else { return nil }
        return url
    }

    private var status: ProjectRunStatus { runtime.status(for: project) }
    private var stateInfo: (totalBytes: Int, lastSaved: Date?) {
        StorageManager.stateInfo(for: project.packageCachePath)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // App header
                HStack(spacing: 14) {
                    AppIconView(project: project)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.appName)
                            .font(.title3.weight(.semibold))
                        Text("v\(project.appVersion)")
                            .foregroundStyle(.secondary)
                        if let publisher = project.publisher {
                            Text(publisher)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Button {
                            projectStore.setFavorite(currentProject, to: !currentProject.isFavorite)
                        } label: {
                            Image(systemName: currentProject.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(currentProject.isFavorite ? Color.yellow : Color.secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .help(currentProject.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                        .accessibilityLabel(currentProject.isFavorite ? "Remove from Favorites" : "Add to Favorites")

                        if lockableURL != nil {
                            Button { toggleFileLock() } label: {
                                Image(systemName: isFileLocked ? "lock.fill" : "lock.open")
                                    .foregroundStyle(isFileLocked ? Color.primary : Color.secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .help(isFileLocked ? "Unlock File" : "Lock File")
                            .accessibilityLabel(isFileLocked ? "Unlock File" : "Lock File")
                        }
                    }
                }
                .task {
                    if let url = lockableURL,
                       let vals = try? url.resourceValues(forKeys: [.isUserImmutableKey]) {
                        isFileLocked = vals.isUserImmutable ?? false
                    }
                }

                // Runtime status
                GroupBox("Runtime") {
                    HStack {
                        Circle()
                            .fill(statusIndicatorColor)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(statusLabel)
                            .font(.subheadline.weight(.medium))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Status: \(statusLabel)")
                    .padding(.vertical, 4)

                    if let msg = runtime.statusMessage(for: project) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(msg)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if status == .running {
                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Enable Local Web Address", isOn: Binding(
                                get: { runtime.isExposed(project) },
                                set: { exposed in
                                    Task {
                                        if exposed {
                                            await runtime.exposeProject(project)
                                        } else {
                                            await runtime.unexposeProject(project)
                                        }
                                        NotificationCenter.default.post(
                                            name: .vibeExposeChanged,
                                            object: nil,
                                            userInfo: ["projectId": project.id, "exposed": exposed]
                                        )
                                    }
                                }
                            ))
                            Text("Makes this app accessible at a local address on your Mac, so you can open it in any browser or app.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)

                        if runtime.isExposed(project), let port = runtime.exposedPort(for: project) {
                            HStack {
                                Text(verbatim: "http://127.0.0.1:\(port)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("http://127.0.0.1:\(port)", forType: .string)
                                }
                                .controlSize(.small)
                            }
                            .padding(.top, 2)
                        }
                    }
                }

                // Saved Data
                GroupBox("Saved Data") {
                    VStack(spacing: 6) {
                        let info = stateInfo
                        if rawPackageSize > 0 {
                            infoRow("Size", formatBytes(rawPackageSize))
                        }
                        if info.lastSaved != nil {
                            infoRow(
                                "Last Saved",
                                info.lastSaved.map {
                                    $0.formatted(date: .abbreviated, time: .shortened)
                                } ?? "—"
                            )
                        }
                        if rawPackageSize == 0 && info.lastSaved == nil {
                            Text("No saved data")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Trust
                GroupBox("Trust Status") {
                    HStack(spacing: 10) {
                        TrustBadge(status: project.trustStatus)
                        if project.isEncrypted {
                            Divider().frame(height: 14)
                            Label("Encrypted", systemImage: "lock.fill")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                // Capabilities
                GroupBox("Capabilities") {
                    VStack(spacing: 6) {
                        CapabilityRow(
                            icon: "globe",
                            label: "Network Access",
                            value: project.capabilities.network ? "Yes" : "No"
                        )
                        CapabilityRow(
                            icon: "folder",
                            label: "Host File Import",
                            value: project.capabilities.allowHostFileImport ? "Yes" : "No"
                        )
                        if !project.capabilities.exposedPorts.isEmpty {
                            CapabilityRow(
                                icon: "number.circle",
                                label: "Exposed Ports",
                                value: project.capabilities.exposedPorts.map(String.init).joined(separator: ", ")
                            )
                        }
                        if !project.capabilities.requiredSecrets.isEmpty {
                            CapabilityRow(
                                icon: "key",
                                label: "Required Secrets",
                                value: project.capabilities.requiredSecrets.joined(separator: ", ")
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Secrets
                if !project.capabilities.secrets.isEmpty {
                    GroupBox("Secrets") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(project.capabilities.secrets, id: \.name) { secret in
                                HStack {
                                    Text(secret.name)
                                        .font(.system(.callout, design: .monospaced))
                                    Spacer()
                                    let isSet = SecretsManager.load(
                                        packageId: project.packageCachePath,
                                        name: secret.name
                                    ) != nil
                                    Label(isSet ? "Set" : "Not set", systemImage: isSet ? "checkmark.circle.fill" : "exclamationmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(isSet ? .green : .orange)
                                }
                            }
                            Divider()
                            Button("Manage Secrets…") { showManageSecrets = true }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Package info
                GroupBox("Package Info") {
                    VStack(spacing: 6) {
                        infoRow("App ID", project.appId)
                        infoRow("Format Version", project.formatVersion)
                        infoRow("Created", project.createdAt)
                        infoRow("Package Hash", String(project.packageHash.prefix(16)) + "…")
                        infoRow("Imported", project.importedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .padding(.vertical, 4)
                }

                // Files
                GroupBox("Files (\(project.files.count))") {
                    let sortedFiles = project.files.keys.sorted()
                    let displayLimit = 200
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedFiles.prefix(displayLimit), id: \.self) { file in
                            HStack {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(file)
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                                if let hash = project.files[file] {
                                    Text(String(hash.prefix(8)))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        if sortedFiles.count > displayLimit {
                            Text("… and \(sortedFiles.count - displayLimit) more files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 400)
        .sheet(isPresented: $showManageSecrets) {
            SecretsEntryView(project: project, mode: .manage)
        }
    }

    private func toggleFileLock() {
        guard var url = lockableURL else { return }
        var vals = URLResourceValues()
        vals.isUserImmutable = !isFileLocked
        do {
            try url.setResourceValues(vals)
            isFileLocked.toggle()
        } catch { }
    }

    private var statusIndicatorColor: Color {
        switch status {
        case .stopped: .gray
        case .starting, .stopping: .orange
        case .running: .green
        case .error: .red
        }
    }

    private var statusLabel: String {
        switch status {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .error: "Error"
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Focused value for DeveloperCommands

struct VibeDocumentContext {
    let project: Project
    let fileURL: URL?
    let revert: () async -> Void
    let showInfo: () -> Void
}

struct VibeDocumentContextKey: FocusedValueKey {
    typealias Value = VibeDocumentContext
}

extension FocusedValues {
    // Scene-scoped so the value stays visible to Commands even when a native
    // view (WKWebView) holds first responder and breaks SwiftUI's focus chain.
    var vibeDocumentContext: VibeDocumentContext? {
        get { self[VibeDocumentContextKey.self] }
        set { self[VibeDocumentContextKey.self] = newValue }
    }
}

// MARK: - Trust Publisher Sheet (TOFU)

/// Shown when a package is signed by a valid key that the user hasn't trusted yet.
private struct TrustPublisherSheet: View {
    let project: Project
    let onProceed: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "questionmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("New Publisher")
                .font(.title2.weight(.semibold))

            Text("\"\(project.appName)\" is signed by a publisher you haven't trusted before. The signature is cryptographically valid \u{2014} the package hasn't been tampered with \u{2014} but you haven't verified who controls this key.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)

            if let fingerprint = project.publisherKeyFingerprint {
                VStack(spacing: 4) {
                    Text(project.publisher ?? "Unknown Publisher")
                        .font(.subheadline.weight(.medium))
                    Text(PublisherTrustStore.shortFingerprint(from: fingerprint))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            Divider()

            HStack(spacing: 12) {
                Button("Open Once") {
                    dismiss()
                    onProceed?()
                }
                .help("Run this time without saving trust. You'll be prompted again next time.")

                Button("Trust Publisher") {
                    if let fingerprint = project.publisherKeyFingerprint {
                        PublisherTrustStore.shared.trust(
                            fingerprint: fingerprint,
                            publisherName: project.publisher ?? "Unknown Publisher"
                        )
                    }
                    dismiss()
                    onProceed?()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .help("Remember this publisher's key and trust future packages from them automatically.")
            }
        }
        .padding(28)
        .frame(minWidth: 400)
    }
}

// MARK: - Trust Warning Sheet

private struct TrustWarningSheet: View {
    let trustStatus: TrustStatus
    let appName: String
    let onProceed: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: isTampered ? "xmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(isTampered ? .red : .orange)

            Text(isTampered ? "Package Verification Failed" : "Unverified Package")
                .font(.title2.weight(.semibold))

            Text(isTampered ? warningTampered : warningUnsigned)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)

            Divider()

            HStack(spacing: 12) {
                if isTampered {
                    Button("Proceed Anyway") {
                        dismiss()
                        onProceed?()
                    }

                    Button("Close") {
                        // Capture the document window (sheet parent) before dismissing,
                        // so the close targets the right window after the sheet disappears.
                        let docWindow = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
                        dismiss()
                        DispatchQueue.main.async { docWindow?.performClose(nil) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.escape)

                    Button("Open Anyway") {
                        dismiss()
                        onProceed?()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 400)
    }

    private var isTampered: Bool { trustStatus == .tampered }

    private var warningTampered: String {
        "The contents of \"\(appName)\" do not match its signature. The package may have been modified by a third party and is not safe to open."
    }

    private var warningUnsigned: String {
        "\"\(appName)\" has no cryptographic signature and cannot be verified as safe. Only open packages from sources you trust."
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let vibeNavigateHome = Notification.Name("app.dotvibe.Vibe.navigateHome")
    static let vibeExposeChanged = Notification.Name("app.dotvibe.Vibe.exposeChanged")
}

// MARK: - Window configurator

/// Applies NSWindow-level settings that require direct access to the window.
/// Placed as a background so it's always in the view hierarchy.
private struct WindowConfigurator: NSViewRepresentable {
    var headerVisible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView.window)
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.toolbar?.isVisible = true  // always show toolbar so (i) is accessible
        window.tabbingMode = .preferred
    }
}
