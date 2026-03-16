import SwiftUI

/// Per-document window: WebKit fills the window, auto-launches on open.
/// An (i) toolbar button opens a sheet with all technical details.
struct DocumentWindowView: View {
    let document: VibeAppDocument
    @State private var runtime = RuntimeState()
    @State private var showInfo = false
    @State private var isWebLoading = true
    @State private var webError: String?
    @State private var currentURL: URL?

    private var project: Project { document.project }
    private var status: ProjectRunStatus { runtime.status(for: project) }

    var body: some View {
        content
            .navigationTitle(project.appName)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showInfo) {
                ProjectInfoSheet(project: project, runtime: runtime)
            }
            .task {
                await runtime.checkRuntime()
                await runtime.launchProject(project)
            }
            .onDisappear {
                let p = project; let rt = runtime
                Task { await rt.stopProject(p) }
            }
            .frame(minWidth: 800, minHeight: 600)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let port = runtime.hostPort(for: project),
           let appURL = URL(string: "http://127.0.0.1:\(port)") {
            ZStack {
                WebView(
                    url: appURL,
                    isLoading: $isWebLoading,
                    loadError: $webError,
                    currentURL: $currentURL
                )
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
                        Task { await runtime.launchProject(project) }
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
    @Environment(\.dismiss) private var dismiss

    private var status: ProjectRunStatus { runtime.status(for: project) }

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
                            Spacer()
                            if status == .running {
                                Button("Stop", role: .destructive) {
                                    dismiss()
                                    let p = project; let rt = runtime
                                    Task { await rt.stopProject(p) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
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
}
