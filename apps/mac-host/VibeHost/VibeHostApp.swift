import SwiftUI
import UniformTypeIdentifiers
import Darwin
import Sparkle

extension UTType {
    static let vibeApp = UTType("ninja.gil.vibe.vibeapp")!
}


@main
struct VibeHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var projectStore = ProjectStore()
    @State private var vaultStore = VaultStore()
    @State private var libraryRuntime = RuntimeState()
    @State private var selectedProject: Project?
    @State private var pendingPackageURL: URL?
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    init() {
        // Ignore SIGPIPE so write() to a closed socket returns EPIPE instead of
        // crashing the process. Required when forcibly shutting down TCP proxy
        // connections (e.g. on bridge removal) while spliceData is still writing.
        signal(SIGPIPE, SIG_IGN)
        // Start the VM immediately so it's warm before any document opens.
        Task { try? await VMManager.shared.ensureReady() }
    }

    var body: some Scene {
        // Primary: each .vibeapp file gets its own window.
        // newDocument:editor: grants the app full read-write file coordination so
        // the Save action can update rawPackageData and macOS writes it to disk.
        DocumentGroup(newDocument: VibeAppDocument()) { file in
            DocumentWindowView(document: file.$document, fileURL: file.fileURL)
        }
        .environment(vaultStore)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.updater.checkForUpdates()
                }
                .disabled(!updaterController.updater.canCheckForUpdates)
            }
            DeveloperCommands()
            ViewCommands()
        }

        // Optional library (Window menu > Library)
        Window("Library", id: "library") {
            LibraryWindowRoot(
                projectStore: projectStore,
                vaultStore: vaultStore,
                libraryRuntime: libraryRuntime,
                selectedProject: $selectedProject,
                pendingPackageURL: $pendingPackageURL
            )
        }
        .environment(vaultStore)

        // Secret Vault window (Window menu > Secret Vault, or ⌘⇧K)
        Window("Secret Vault", id: "vault") {
            NavigationStack {
                VaultView()
            }
        }
        .environment(vaultStore)
        .defaultSize(width: 560, height: 480)
        .keyboardShortcut(KeyboardShortcut("k", modifiers: [.command, .shift]))
    }
}

// MARK: - Library Window Root

/// Wraps the library NavigationSplitView so it has access to SwiftUI environment actions.
private struct LibraryWindowRoot: View {
    let projectStore: ProjectStore
    let vaultStore: VaultStore
    let libraryRuntime: RuntimeState
    @Binding var selectedProject: Project?
    @Binding var pendingPackageURL: URL?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
                    ToolbarItem {
                        Button {
                            openWindow(id: "vault")
                        } label: {
                            Label("Secret Vault", systemImage: "key.horizontal.fill")
                        }
                        .help("Open Secret Vault (⌘⇧K)")
                    }
                }
        } detail: {
            if let project = selectedProject {
                ProjectDetailView(
                    project: project,
                    runtime: libraryRuntime,
                    onRemove: {
                        projectStore.removeProject(project)
                        selectedProject = nil
                    }
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
        .task {
            await libraryRuntime.checkRuntime()
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

// MARK: - VM Status Bar

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

// MARK: - View Commands

struct ViewCommands: Commands {
    @AppStorage("vibeHeaderVisible") private var headerVisible = true

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(headerVisible ? "Hide Header" : "Show Header") {
                headerVisible.toggle()
            }
        }
    }
}

// MARK: - Document Controller

/// Custom document controller so the tab bar "+" navigates the current app home
/// instead of creating a blank document that can't launch.
final class VibeDocumentController: NSDocumentController {
    override func newDocument(_ sender: Any?) {
        if currentDocument?.fileURL != nil {
            // A vibe document is open — navigate it to its home page.
            NotificationCenter.default.post(name: .vibeNavigateHome, object: nil)
        } else {
            super.newDocument(sender)
        }
    }
}

// MARK: - App Delegate

/// Manages the Developer menu's Option-key visibility.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Instantiate our custom document controller before SwiftUI touches it.
        // applicationWillFinishLaunching is the documented Cocoa hook for this.
        _ = VibeDocumentController()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Defer until SwiftUI has finished populating NSApp.mainMenu.
        DispatchQueue.main.async {
            self.developerMenuItem?.isHidden = true
        }
        installMonitors()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-evaluate in case Option was already held when the app came to front.
        updateVisibility()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Always hide when the app loses focus so it isn't left visible.
        developerMenuItem?.isHidden = true
    }

    deinit {
        localMonitor.map(NSEvent.removeMonitor)
        globalMonitor.map(NSEvent.removeMonitor)
    }

    // MARK: - Private

    private var developerMenuItem: NSMenuItem? {
        NSApp.mainMenu?.items.first { $0.title == "Developer" }
    }

    private func updateVisibility() {
        developerMenuItem?.isHidden = !NSEvent.modifierFlags.contains(.option)
    }

    private func installMonitors() {
        // Local monitor: fires while our app is key (covers typing ⌥ in our windows).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateVisibility()
            return event
        }
        // Global monitor: fires when the user holds ⌥ while our app is already frontmost
        // but the event originates outside our windows (e.g. clicking the menu bar).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            DispatchQueue.main.async { self?.updateVisibility() }
        }
    }
}
