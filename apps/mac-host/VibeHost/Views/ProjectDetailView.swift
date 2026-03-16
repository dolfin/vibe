import SwiftUI
import os

private let logger = Logger(subsystem: "ninja.gil.VibeHost", category: "ProjectDetail")

/// Detail view for a single project.
struct ProjectDetailView: View {
    let project: Project
    @Bindable var runtime: RuntimeState
    var onRemove: (() -> Void)? = nil

    @State private var showBrowser = false

    private var status: ProjectRunStatus {
        runtime.status(for: project)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                runtimeControls
                trustSection
                capabilitiesSection
                packageInfoSection
                filesSection
                removeSection
            }
            .padding()
        }
        .navigationTitle(project.appName)
        .sheet(isPresented: $showBrowser) {
            if let port = runtime.hostPort(for: project),
               let url = URL(string: "http://127.0.0.1:\(port)") {
                AppBrowserView(url: url, appName: project.appName)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
            VStack(alignment: .leading) {
                Text(project.appName)
                    .font(.title2.weight(.semibold))
                Text("v\(project.appVersion)")
                    .foregroundStyle(.secondary)
                if let publisher = project.publisher {
                    Text(publisher)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Runtime Controls

    private var runtimeControls: some View {
        GroupBox {
            VStack(spacing: 12) {
                HStack {
                    statusIndicator
                    Spacer()
                    controlButtons
                }

                if let msg = runtime.statusMessage(for: project) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(msg)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error = runtime.lastError {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !VMManager.shared.isReady {
                    vmStatusRow
                }
            }
        } label: {
            Text("Runtime")
        }
        .task {
            await runtime.checkRuntime()
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusLabel)
                .font(.subheadline.weight(.medium))

            if let port = runtime.hostPort(for: project), status == .running {
                Text("port \(port)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
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
        case .starting: "Starting..."
        case .running: "Running"
        case .stopping: "Stopping..."
        case .error: "Error"
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        HStack(spacing: 8) {
            switch status {
            case .stopped, .error:
                Button {
                    Task { await launchProject() }
                } label: {
                    Label("Launch", systemImage: "play.fill")
                }
                .disabled(!VMManager.shared.isReady)

            case .starting, .stopping:
                ProgressView()
                    .controlSize(.small)

            case .running:
                Button {
                    showBrowser = true
                } label: {
                    Label("Open", systemImage: "globe")
                }

                Button {
                    Task { await runtime.stopProject(project) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(.red)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    @ViewBuilder
    private var vmStatusRow: some View {
        switch VMManager.shared.state {
        case .booting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting Vibe Runtime…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle").foregroundStyle(.red)
                Text("Runtime failed: \(msg)")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        default:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Vibe Runtime not running")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func launchProject() async {
        logger.info("Launching project: \(project.appName)")
        await runtime.launchProject(project)
    }

    // MARK: - Info Sections

    private var trustSection: some View {
        GroupBox("Trust Status") {
            HStack {
                TrustBadge(status: project.trustStatus)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var capabilitiesSection: some View {
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
    }

    private var packageInfoSection: some View {
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
    }

    private var filesSection: some View {
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

    @ViewBuilder
    private var removeSection: some View {
        if let onRemove {
            HStack {
                Spacer()
                Button("Remove Project", role: .destructive) {
                    onRemove()
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}
