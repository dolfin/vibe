import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let vibeApp = UTType(importedAs: "ninja.gil.vibe.vibeapp")
}

@main
struct VibeHostApp: App {
    @State private var projectStore = ProjectStore()
    @State private var runtimeState = RuntimeState()
    @State private var selectedProject: Project?
    @State private var pendingPackageURL: URL?

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                LibraryView(store: projectStore, selectedProject: $selectedProject)
                    .toolbar {
                        ToolbarItem {
                            Button {
                                openFilePanel()
                            } label: {
                                Label("Open...", systemImage: "plus")
                            }
                        }
                    }
            } detail: {
                if let project = selectedProject {
                    ProjectDetailView(
                        project: project,
                        store: projectStore,
                        runtime: runtimeState,
                        onRemove: { selectedProject = nil }
                    )
                } else {
                    Text("Select a project")
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VMStatusBar()
            }
            .sheet(item: $pendingPackageURL) { url in
                OpenPackageView(
                    packageURL: url,
                    store: projectStore,
                    onImported: { project in
                        selectedProject = project
                    }
                )
            }
            .onOpenURL { url in
                if url.pathExtension == "vibeapp" {
                    pendingPackageURL = url
                }
            }
            .task {
                do {
                    try await VMManager.shared.ensureReady()
                    await runtimeState.checkRuntime()
                } catch {
                    // VMManager sets .failed state — no extra handling needed here
                }
            }
        }
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.vibeApp]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a .vibeapp package to open"

        if panel.runModal() == .OK, let url = panel.url {
            pendingPackageURL = url
        }
    }
}

/// Persistent bottom status bar showing Vibe Runtime warm-up state.
private struct VMStatusBar: View {
    private var vmState: VMManager.State { VMManager.shared.state }

    var body: some View {
        switch vmState {
        case .ready, .idle:
            EmptyView()
        case .booting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting Vibe Runtime — launch will be available shortly…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        case .stopping:
            EmptyView()
        case .failed(let msg):
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("Runtime failed: \(msg)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }
}

// Make URL conform to Identifiable for .sheet(item:)
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
