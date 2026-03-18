import SwiftUI
import os

private let logger = Logger(subsystem: "ninja.gil.Vibe", category: "ProjectDetail")

/// Detail view for a single project.
struct ProjectDetailView: View {
    let project: Project
    @Bindable var runtime: RuntimeState
    var onRemove: (() -> Void)? = nil

    @Environment(VaultStore.self) private var vaultStore

    private enum ActiveSheet: Identifiable {
        case browser
        case secrets(SecretsEntryView.Mode)
        var id: String {
            switch self {
            case .browser: "browser"
            case .secrets(let m): "secrets-\(m == .launch ? "launch" : "manage")"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?

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
                if !project.capabilities.secrets.isEmpty {
                    secretsSection
                }
                packageInfoSection
                filesSection
                removeSection
            }
            .padding()
        }
        .navigationTitle(project.appName)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .browser:
                if let ep = runtime.vmEndpoint(for: project) {
                    AppBrowserView(
                        appURL: runtime.isExposed(project)
                            ? URL(string: "http://127.0.0.1:\(ep.hostPort)/")!
                            : URL(string: "vibe-app://app/")!,
                        schemeHandler: runtime.isExposed(project) ? nil
                            : VibeSchemeHandler(vmIP: ep.vmIP, port: ep.hostPort),
                        appName: project.appName
                    )
                }
            case .secrets(let mode):
                SecretsEntryView(
                    project: project,
                    mode: mode,
                    onComplete: mode == .launch ? { secrets in
                        Task { await runtime.launchProject(project, secrets: secrets) }
                    } : nil
                )
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
                    activeSheet = .browser
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
        let missing = project.capabilities.requiredSecrets.filter { envVar in
            vaultStore.binding(packageId: project.packageCachePath, envVar: envVar) == nil &&
            SecretsManager.load(packageId: project.packageCachePath, name: envVar) == nil
        }
        if missing.isEmpty {
            let secrets = resolveSecrets()
            await runtime.launchProject(project, secrets: secrets)
        } else {
            activeSheet = .secrets(.launch)
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

    // MARK: - Info Sections

    private var secretsSection: some View {
        GroupBox("Secrets") {
            Button("Manage Secrets…") {
                activeSheet = .secrets(.manage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var trustSection: some View {
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
                if !project.capabilities.secrets.isEmpty {
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
