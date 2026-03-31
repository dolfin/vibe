import SwiftUI
import UniformTypeIdentifiers
import Darwin
import Sparkle

extension UTType {
    static let vibeApp = UTType(exportedAs: "app.dotvibe.vibe.vibeapp")
}


@main
struct VibeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var projectStore = ProjectStore()
    @State private var vaultStore = VaultStore()
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
                .onAppear { appDelegate.openLibrary = { openWindow(id: "library") } }
        }
        .environment(vaultStore)
        .environment(projectStore)
        .commands {
            NewItemCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.updater.checkForUpdates()
                }
                .disabled(!updaterController.updater.canCheckForUpdates)
            }
            DeveloperCommands()
            GetInfoCommands()
            ViewCommands()
            HelpCommands()
        }

        // Optional library (Window menu > Library)
        Window("Library", id: "library") {
            LibraryWindowRoot(projectStore: projectStore)
        }
        .defaultSize(width: 400, height: 520)
        .windowResizability(.contentMinSize)

        // Acknowledgments window (Help > Acknowledgments…)
        Window("Acknowledgments", id: "acknowledgments") {
            AcknowledgmentsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 700, height: 480)
        .commandsRemoved()

        // Get Started window (File > New or ⌘N)
        Window("Get Started", id: "get-started") {
            GetStartedView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 480)
        .commandsRemoved()

        // Saved Keys window (Window menu > Saved Keys, or ⌘⇧K)
        Window("Saved Keys", id: "vault") {
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

private struct LibraryWindowRoot: View {
    let projectStore: ProjectStore

    @State private var importError: String?

    var body: some View {
        LibraryView(store: projectStore)
            .navigationTitle("Apps")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Browse…") { browseAndOpen() }
                        .keyboardShortcut("o", modifiers: .command)
                }
            }
            .alert("Cannot Open App", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "The app could not be opened. The file may be damaged or incompatible.")
            }
    }

    /// Shows an open panel and opens the selected package as a document.
    private func browseAndOpen() {
        let panel = NSOpenPanel()
        // Prefer resolving via extension so the panel works even if the exported
        // UTI hasn't propagated through lsd yet (e.g. after a bundle-ID change).
        panel.allowedContentTypes = [.vibeApp]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // VibeAppDocument.init handles decryption, icon caching, and trust verification.
        // DocumentWindowView.task calls registerOpened, which adds the project to the library.
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                DispatchQueue.main.async { importError = error.localizedDescription }
            }
        }
    }
}

// MARK: - New Item Commands

struct NewItemCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New…") {
                openWindow(id: "get-started")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}

// MARK: - Get Info Command

struct GetInfoCommands: Commands {
    @FocusedValue(\.vibeDocumentContext) private var docContext

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            Button {
                docContext?.showInfo()
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(docContext == nil)
        }
    }
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

// MARK: - Help Commands

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Vibe Help") {
                NSWorkspace.shared.open(URL(string: "https://docs.dotvibe.app")!)
            }
            Divider()
            Button("Acknowledgments…") {
                openWindow(id: "acknowledgments")
            }
        }
    }
}

// MARK: - App Delegate

/// Manages the Developer menu's Option-key visibility and library opening on launch.
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var localMonitor: Any?
    private var globalMonitor: Any?

    /// Set to true if the app was launched by opening a .vibeapp file.
    private(set) var openedViaFile = false

    /// Wired by VibeApp.body once the SwiftUI environment is available.
    var openLibrary: (() -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        openedViaFile = true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Defer until SwiftUI has finished populating NSApp.mainMenu.
        DispatchQueue.main.async {
            self.developerMenuItem?.isHidden = true
        }
        installMonitors()

        // Open library on launch whenever the app wasn't triggered by a file open.
        DispatchQueue.main.async {
            if !self.openedViaFile {
                self.openLibrary?()
            }
        }
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
