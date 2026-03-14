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
                        runtime: runtimeState
                    )
                } else {
                    Text("Select a project")
                        .foregroundStyle(.secondary)
                }
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

// Make URL conform to Identifiable for .sheet(item:)
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
