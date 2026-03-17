import SwiftUI
import AppKit
import os

private let logger = Logger(subsystem: "ninja.gil.VibeHost", category: "DocumentWindow")

/// Per-document window: WebKit fills the window, auto-launches on open.
/// An (i) toolbar button opens a sheet with all technical details.
struct DocumentWindowView: View {
    @Binding var document: VibeAppDocument
    let fileURL: URL?
    @State private var runtime = RuntimeState()
    @State private var isWebLoading = true
    @State private var webError: String?
    @State private var currentURL: URL?
    @State private var schemeHandler: VibeSchemeHandler?
    @State private var webViewID = UUID()
    @State private var pollingTask: Task<Void, Never>?

    private enum ActiveSheet: Identifiable {
        case info, secrets
        var id: String { switch self { case .info: "info"; case .secrets: "secrets" } }
    }
    @State private var activeSheet: ActiveSheet?

    private var project: Project { document.project }
    private var status: ProjectRunStatus { runtime.status(for: project) }

    var body: some View {
        content
            .navigationTitle(project.appName)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        activeSheet = .info
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .info:
                    ProjectInfoSheet(
                        project: project,
                        runtime: runtime,
                        fileURL: fileURL,
                        schemeHandler: $schemeHandler,
                        webViewID: $webViewID
                    )
                case .secrets:
                    SecretsEntryView(project: project, mode: .launch) { secrets in
                        Task { await doLaunch(secrets: secrets) }
                    }
                }
            }
            .task {
                await runtime.checkRuntime()
                await launchCurrentProject()
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
            .onDisappear {
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
            .focusedValue(\.vibeDocumentContext, VibeDocumentContext(
                project: project,
                fileURL: fileURL,
                revert: { await revertAction() }
            ))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if runtime.isExposed(project), let port = runtime.exposedPort(for: project),
           let appURL = URL(string: "http://127.0.0.1:\(port)") {
            ZStack {
                WebView(
                    url: appURL,
                    schemeHandler: nil,
                    isLoading: $isWebLoading,
                    loadError: $webError,
                    currentURL: $currentURL
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
        } else if let handler = schemeHandler {
            ZStack {
                WebView(
                    url: URL(string: "vibe-app://app/")!,
                    schemeHandler: handler,
                    isLoading: $isWebLoading,
                    loadError: $webError,
                    currentURL: $currentURL
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
        } else {
            launchingOverlay
        }
    }

    // MARK: - Launch

    private func launchCurrentProject() async {
        let missing = project.capabilities.requiredSecrets.filter {
            SecretsManager.load(packageId: project.packageCachePath, name: $0) == nil
        }
        if missing.isEmpty {
            let secrets = SecretsManager.loadAll(
                packageId: project.packageCachePath,
                names: project.capabilities.declaredSecrets
            )
            await doLaunch(secrets: secrets)
        } else {
            activeSheet = .secrets
        }
    }

    private func doLaunch(secrets: [String: String] = [:]) async {
        await runtime.launchProject(project, secrets: secrets)
        if let ep = runtime.vmEndpoint(for: project) {
            schemeHandler = VibeSchemeHandler(vmIP: ep.vmIP, port: ep.hostPort)
        }
        startVolumePolling()
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
        try? FileManager.default.removeItem(at: stateDir)

        // Step 4: Write the clean (state-free) cached package back to disk.
        let cacheURL = StorageManager.packageCacheDir
            .appendingPathComponent(project.packageCachePath)
            .appendingPathComponent("package.vibeapp")
        guard let cleanData = try? Data(contentsOf: cacheURL) else { return }
        document.rawPackageData = cleanData
        NSApp.sendAction(Selector(("saveDocument:")), to: nil, from: nil)

        // Step 5: Relaunch. prepare() will find no savedState and no initialState,
        // so the volume directory starts completely empty.
        await launchCurrentProject()
        logger.info("Reverted to original state and reloaded")
    }

    // MARK: - Overlays

    private var launchingOverlay: some View {
        VStack(spacing: 20) {
            Image(systemName: "app.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

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

// MARK: - Info Sheet

private struct ProjectInfoSheet: View {
    let project: Project
    let runtime: RuntimeState
    let fileURL: URL?
    @Binding var schemeHandler: VibeSchemeHandler?
    @Binding var webViewID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var showManageSecrets = false

    private var status: ProjectRunStatus { runtime.status(for: project) }
    private var stateInfo: (totalBytes: Int, lastSaved: Date?) {
        StorageManager.stateInfo(for: project.packageCachePath)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
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
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Runtime status
                    GroupBox("Runtime") {
                        HStack {
                            Circle()
                                .fill(statusIndicatorColor)
                                .frame(width: 10, height: 10)
                            Text(statusLabel)
                                .font(.subheadline.weight(.medium))
                        }
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

                            Toggle("Expose to machine", isOn: Binding(
                                get: { runtime.isExposed(project) },
                                set: { exposed in
                                    Task {
                                        if exposed {
                                            await runtime.exposeProject(project)
                                            schemeHandler = nil
                                        } else {
                                            await runtime.unexposeProject(project)
                                            if let ep = runtime.vmEndpoint(for: project) {
                                                schemeHandler = VibeSchemeHandler(
                                                    vmIP: ep.vmIP,
                                                    port: ep.hostPort
                                                )
                                            }
                                        }
                                        webViewID = UUID()
                                    }
                                }
                            ))
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
                            if info.totalBytes > 0 || info.lastSaved != nil {
                                infoRow("Size", formatBytes(info.totalBytes))
                                infoRow(
                                    "Last Saved",
                                    info.lastSaved.map {
                                        $0.formatted(date: .abbreviated, time: .shortened)
                                    } ?? "—"
                                )
                            } else {
                                Text("No saved data")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // Trust
                    GroupBox("Trust Status") {
                        HStack {
                            TrustBadge(status: project.trustStatus)
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
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(project.files.keys.sorted(), id: \.self) { file in
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
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 420, minHeight: 500)
        .sheet(isPresented: $showManageSecrets) {
            SecretsEntryView(project: project, mode: .manage)
        }
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
}

struct VibeDocumentContextKey: FocusedValueKey {
    typealias Value = VibeDocumentContext
}

extension FocusedValues {
    var vibeDocumentContext: VibeDocumentContext? {
        get { self[VibeDocumentContextKey.self] }
        set { self[VibeDocumentContextKey.self] = newValue }
    }
}
