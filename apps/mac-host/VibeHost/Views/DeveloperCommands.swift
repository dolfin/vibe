import SwiftUI
import AppKit

struct DeveloperCommands: Commands {
    var body: some Commands {
        CommandMenu("Developer") {
            Button("Clear Caches…") {
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "Clear All Caches?"
                    alert.informativeText = "This stops the VM and deletes the package cache and Docker image cache (data.img). The app package cache is also cleared. Next boot will re-download everything."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Clear Caches")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    await VMManager.shared.clearCaches()
                }
            }
            Divider()
            Button("Open VM Console Log") {
                NSWorkspace.shared.open(VMManager.shared.consoleLogURL)
            }
        }
    }
}
